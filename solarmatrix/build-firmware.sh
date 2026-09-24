#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the SolarMatrix firmware from this OpenWRT fork.
# Takes an optional OpenWRT tag argument -- without one it builds PINNED_TAG;
# the word "latest" resolves to the newest stable upstream release tag --
# builds, and emits firmware + licenses JSON under solarmatrix/out/.
#
# "latest" is resolved once, up front, and everything downstream sees the
# concrete tag it resolved to: the checkout, CONFIG_VERSION_NUMBER, the image
# names, tag.txt and the license manifest. A build is therefore still reproducible after the
# fact, because the artifacts record which tag was actually built.
#
# This script is part of the GPL-2.0 OpenWRT fork. It contains no proprietary
# SolarMatrix code and never reads from the controller repository.

set -euo pipefail

install_prereqs() {
    echo "==== Installing OpenWRT build prerequisites ===="
    export DEBIAN_FRONTEND=noninteractive

    sudo apt-get update
    sudo apt-get install -y \
        build-essential clang flex bison g++ gawk \
        gettext git libncurses5-dev libssl-dev \
        python3-setuptools python3-dev rsync swig unzip zlib1g-dev file wget \
        device-tree-compiler jq

    echo "Prerequisites installed"
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/solarmatrix/out"

cd "$REPO_ROOT"

step() { echo -e "\n==== $* ===="; }

if [ "${1:-}" = "prereqs" ]; then
    install_prereqs
    exit 0
fi

# The tag this firmware is pinned to. A build with no argument builds this,
# so the pin lives in git and a plain ./build-firmware.sh is reproducible.
# An explicit tag or "latest" still overrides it.
PINNED_TAG="v25.12.5"

if [ $# -gt 1 ]; then
    echo "usage: $0 [<openwrt-tag>|latest]" >&2
    echo "Example: $0                # build the pinned tag ($PINNED_TAG)" >&2
    echo "         $0 v25.12.5       # build a named release" >&2
    echo "         $0 latest         # newest stable upstream release" >&2
    exit 1
fi
TAG="${1:-$PINNED_TAG}"

# "latest" means the newest stable upstream release tag. Release candidates
# are excluded: an rc is not something to ship. Sorting is -V so that
# v25.12.10 would rank above v25.12.9 rather than below it, which a plain
# lexical sort gets wrong the moment a series reaches double digits.
if [ "$TAG" = "latest" ]; then
    step "Resolving 'latest' to the newest stable upstream tag"
    TAG="$(git tag -l 'v[0-9]*' | grep -vE -- '-?rc[0-9]*$' | sort -V | tail -1)"
    if [ -z "$TAG" ]; then
        echo "ERROR: no stable vN tags found. Fetch them first:" >&2
        echo "  git fetch upstream --tags   # or: git fetch origin --tags" >&2
        exit 1
    fi
    echo "Resolved: $TAG"
fi

# Refuse to clobber a pre-existing version file or rootfs overlay. We register
# the cleanup trap only AFTER these checks so the trap can never delete a file
# the script didn't create.
for GENERATED in version files; do
    if [ -e "$REPO_ROOT/$GENERATED" ]; then
        echo "ERROR: $REPO_ROOT/$GENERATED already exists; refusing to overwrite" >&2
        echo "  Remove it manually if it's leftover from a prior failed run." >&2
        exit 1
    fi
done

# Cleanup the top-level 'version' override and 'files' overlay so they don't
# pollute future builds run outside this script. Once the DTS has been patched
# it is restored from the tag as well, on success and on failure: left
# modified, it would make the next run's tag checkout refuse to switch. The
# restore waits for DTS_PATCHED so an early failure, before the tag checkout,
# never touches the invoking branch's copy.
DTS="target/linux/mediatek/dts/mt7981b-openwrt-one.dts"
DTS_PATCHED=""
cleanup() {
    rm -rf "$REPO_ROOT/version" "$REPO_ROOT/files" "$REPO_ROOT"/package/boot/uboot-mediatek/patches/9*-solarmatrix-*.patch
    if [ -n "$DTS_PATCHED" ]; then
        git -C "$REPO_ROOT" checkout -q "refs/tags/$TAG" -- "$DTS" ||
            echo "WARNING: could not restore $DTS from $TAG" >&2
    fi
}
# INT and TERM only exit; the EXIT trap then cleans up once, and the build does
# not resume after the interrupted command.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step "Target OpenWRT tag: $TAG"

# Capture invoking branch so we can overlay solarmatrix/ after detach.
INVOKING_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
if [ -z "$INVOKING_BRANCH" ]; then
    echo "ERROR: refusing to run on detached HEAD." >&2
    echo "Check out a branch containing the solarmatrix/ dir first," >&2
    echo "then re-run this script." >&2
    exit 1
fi

step "Checking out $TAG (detached)"
# Force tag-scoped resolution so a branch name, commit SHA, "-",
# or other arg form can't masquerade as a TAG.
git rev-parse --verify "refs/tags/$TAG^{commit}" >/dev/null 2>&1 || {
    echo "ERROR: '$TAG' is not a tag (no refs/tags/$TAG)" >&2
    exit 1
}
git checkout --detach "refs/tags/$TAG"

step "Overlaying solarmatrix/ from $INVOKING_BRANCH"
git checkout "$INVOKING_BRANCH" -- solarmatrix/

# The build's checks live in build-gates.sh so build-gates_test.sh can run them
# against fake trees.
# shellcheck source=build-gates.sh
. "$REPO_ROOT/solarmatrix/build-gates.sh"

# OpenWRT's package/install copies $TOPDIR/files verbatim over the rootfs
# (include/rootfs.mk: prepare_rootfs). That is how the SolarMatrix hardening
# scripts get into the image; the tag checkout above does not carry them, so
# stage them on every build. Every entry must be in build-gates.sh's overlay
# lists, so none can ship without the post-build check.
step "Staging solarmatrix/files as the rootfs overlay"
check_overlay_listed "$REPO_ROOT/solarmatrix/files"
cp -a "$REPO_ROOT/solarmatrix/files" "$REPO_ROOT/files"

# Package patches live under solarmatrix/ for the same reason: the tag checkout
# above restores only solarmatrix/ from our branch, so a patch committed under
# package/ would silently never reach the build. OpenWRT hashes the patch
# directory into the package's prepared stamp, so adding or removing one forces
# U-Boot to be re-extracted and rebuilt.
step "Staging SolarMatrix U-Boot patches"
cp "$REPO_ROOT"/solarmatrix/patches/uboot-mediatek/*.patch \
    "$REPO_ROOT/package/boot/uboot-mediatek/patches/"

# A previous build's copy of an overlay file would satisfy the post-build check
# even if this build never applied the overlay, so delete them first.
[ ! -d build_dir ] || delete_stale_overlay build_dir

# The release version number is CONFIG_VERSION_NUMBER. It is what ends up in
# DISTRIB_RELEASE in /etc/openwrt_release, and it is the number a person means
# by "which OpenWRT is this".
#
# It is deliberately NOT written to the top-level "version" file. That file
# feeds scripts/getver.sh, which sets REVISION -- a different thing, meant to
# look like r28790-abc123def. base-files composes its own package version from
# it as PKG_RELEASE~<last dash-separated field of REVISION>, normally a git
# hash. Pinning REVISION to a release number puts dots there, and apk rejects
# the result:
#
#   apk mkpkg --info "version:1711~25.12.5"
#   ERROR: info field 'version' has invalid value: package version is invalid
#
# apk accepts 1711~abc123de and 1711~25125 but not 1711~25.12.5, so a dotted
# REVISION fails the build at package/base-files. REVISION is therefore left
# to git, which is reproducible anyway because a fixed tag is checked out.
VERSION_NUMBER="${TAG#v}"

step "Updating and installing package feeds"
mkdir -p tmp
./scripts/feeds update -a
./scripts/feeds install -a

# Two changes to the stock OpenWRT One DTS, made by openwrt-one-dts.py (which
# documents them): userspace SPI for the MCP2515 CAN module on the mikroBUS
# SPI bus, and the NOR factory partition split into a read-only factory
# <0x40000 0xa0000> and a writable factory-secrets <0xe0000 0x20000>.
#
# The result is verified rather than assumed: these are regex edits against an
# upstream file, and a pattern that silently matched nothing would otherwise
# yield firmware with no CAN access or no secrets partition, and no error
# anywhere in the log. The NOR partition table is then checked as a whole, and
# checked again in the compiled DTB after the build.
#
# The tag checkout keeps local modifications to files the tag also has, so a
# DTS patched by an earlier, interrupted run would be patched twice. It is
# restored from the tag first, the result is written only once every check
# has passed, and the exit trap restores it again.
step "Patching the OpenWRT One DTS (userspace SPI, factory-secrets partition)"
if [ ! -f "$DTS" ]; then
    echo "ERROR: DTS not found: $DTS" >&2
    exit 1
fi
DTS_PATCHED=1
git checkout -q "refs/tags/$TAG" -- "$DTS"
python3 "$REPO_ROOT/solarmatrix/openwrt-one-dts.py" patch "$DTS" "$TAG"

step "Writing .config for OpenWRT One (mediatek/filogic)"
cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y

# Userspace SPI. The controller drives the MCP2515 itself over
# /dev/spidev2.0 rather than through the kernel CAN stack, so this is what
# makes the CAN module reachable at all. Without it there is no device node.
CONFIG_PACKAGE_kmod-spi-dev=y

# The SSD. /solarmatrix lives there, so without kmod-nvme the disk is
# invisible and nothing the device stores survives a reboot. ext4 is the only
# filesystem involved: the provisioning tool formats the partition ext4 and
# mounts it, and nothing on the device reads any other kind.
CONFIG_PACKAGE_kmod-nvme=y
CONFIG_PACKAGE_kmod-fs-ext4=y

# Disk preparation, used by the provisioning tool over SSH: it runs
# "parted mklabel gpt", "parted mkpart primary ext4" and then "mkfs.ext4".
# BusyBox has no parted, and mkfs.ext4 comes from e2fsprogs.
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_e2fsprogs=y

# blkid identifies the NVMe partition; all three of the on-device storage
# scripts in solarmatrix/files call it.
CONFIG_PACKAGE_blkid=y

# curl is run on the device by the provisioning tool's verification step,
# "curl -f -s -o /dev/null http://127.0.0.1/", to prove the controller is
# serving before the run is allowed to succeed.
CONFIG_PACKAGE_curl=y

# Public trust roots. The relay client pins RootCAs to the device's own
# ca.crt and needs none of these, but the clone report in
# internal/relay/clone.go sets no RootCAs at all, so it falls back to the
# system pool to reach api.solarmatrix.eu. Without this that call fails with
# an unknown-authority error.
CONFIG_PACKAGE_ca-certificates=y

# LUKS2 for the NVMe: storage.sh opens it with cryptsetup. kmod-dm carries
# dm-crypt; the aes-xts cipher needs xts.
CONFIG_PACKAGE_cryptsetup=y
CONFIG_PACKAGE_kmod-dm=y
CONFIG_PACKAGE_kmod-crypto-xts=y

# The household LAN is IPv4 only. Outgoing IPv6 uses odhcp6c, a separate
# package; odhcpd is the LAN-side DHCPv6/RA server, runs as root, and is a
# default package of the target, so it has to be deselected explicitly.
# CONFIG_PACKAGE_odhcpd-ipv6only is not set
EOF

# Appended rather than placed in the heredoc above, which is quoted so that
# nothing else in it is expanded.
#
# CONFIG_VERSION_NUMBER sits inside "menuconfig VERSIONOPT", whose own prompt
# exists only "if IMAGEOPT", so both gates are needed. Without them defconfig
# drops the version silently and the image is built as SNAPSHOT. Established
# by testing defconfig directly rather than by reading Kconfig:
#
#   VERSION_NUMBER alone        -> dropped
#   + CONFIG_VERSIONOPT=y       -> dropped
#   + CONFIG_IMAGEOPT=y as well -> kept
#
# Failsafe gives a passwordless root shell on a key press during preinit.
# TARGET_PREINIT_DISABLE_FAILSAFE sits inside "menuconfig PREINITOPT", whose
# prompt likewise exists only "if IMAGEOPT" (package/base-files/image-config.in).
{
    printf 'CONFIG_IMAGEOPT=y\n'
    printf 'CONFIG_VERSIONOPT=y\n'
    printf 'CONFIG_VERSION_NUMBER="%s"\n' "$VERSION_NUMBER"
    printf 'CONFIG_PREINITOPT=y\n'
    printf 'CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE=y\n'
} >> .config
make defconfig

# defconfig drops unknown symbols without comment, so confirm what this device
# depends on is still selected, and what it must not have is not.
step "Verifying .config after defconfig"
check_defconfig .config "$VERSION_NUMBER"

step "Building (this is slow)"
make -j"$(nproc)" V=s

# version.buildinfo now carries the git revision, which is the correct thing
# for it to carry. What matters to a person holding the device is
# DISTRIB_RELEASE, so check that instead -- and check it in the rootfs that
# was actually staged, not in a build variable.
step "Verifying the release version reached the rootfs"
ROOTFS_DIR="$(find_rootfs_dir build_dir)"
RELEASE_FILE="$ROOTFS_DIR/etc/openwrt_release"
if ! grep -q "^DISTRIB_RELEASE='$VERSION_NUMBER'\$" "$RELEASE_FILE" 2>/dev/null; then
    echo "ERROR: $RELEASE_FILE does not report DISTRIB_RELEASE='$VERSION_NUMBER'" >&2
    grep '^DISTRIB_RELEASE=' "$RELEASE_FILE" 2>/dev/null >&2 || echo "  (no DISTRIB_RELEASE line)" >&2
    exit 1
fi
echo "Verified: DISTRIB_RELEASE='$VERSION_NUMBER'"

# An overlay file that silently failed to reach the rootfs would ship a device
# without its access policy or its fail-closed storage, so make it a build
# failure rather than a surprise in the field.
step "Verifying the SolarMatrix overlay reached the rootfs"
check_overlay_in_rootfs "$REPO_ROOT/solarmatrix/files" "$ROOTFS_DIR"

# Stock OpenWrt One U-Boot flashes or boots unsigned images from a button press
# at power-on, and falls back to TFTP when both NAND systems fail. The 900 patch
# removes those paths; check the built binaries, not the patch, so a patch that
# stopped applying cannot ship a U-Boot that still has them. u-boot.bin is read
# from build_dir because the NOR .fip is compressed and shows no env text.
step "Verifying U-Boot has no unsigned recovery paths"
for UBOOT_CHECK in \
    "nor|bootcmd=run led_start ; mtd read recovery" \
    "snand|bootcmd=run led_start ; run boot_calibration" \
    "snand|boot_default=run bootcmd ; run boot_recovery ; run led_loop_error" \
; do
    UBOOT_VARIANT="${UBOOT_CHECK%%|*}"
    UBOOT_EXPECT="${UBOOT_CHECK#*|}"
    UBOOT_BIN="$(find build_dir -maxdepth 4 -path "*/u-boot-mt7981_openwrt_one-$UBOOT_VARIANT/u-boot-*/u-boot.bin" | head -1)"
    if [ -z "$UBOOT_BIN" ]; then
        echo "ERROR: no u-boot.bin for openwrt_one-$UBOOT_VARIANT under build_dir" >&2
        exit 1
    fi
    if grep -a -q 'bootcmd=run check_button' "$UBOOT_BIN"; then
        echo "ERROR: $UBOOT_BIN still runs the button recovery checks at boot" >&2
        exit 1
    fi
    if ! grep -a -q -F "$UBOOT_EXPECT" "$UBOOT_BIN"; then
        echo "ERROR: $UBOOT_BIN lacks: $UBOOT_EXPECT" >&2
        exit 1
    fi
    echo "Verified: openwrt_one-$UBOOT_VARIANT: $UBOOT_EXPECT"
done

step "Verifying failsafe, serial login, odhcpd, SSH defaults and image size"
check_rootfs_gates "$ROOTFS_DIR"
check_initramfs bin/targets "$VERSION_NUMBER"

# The source check of the NOR table cannot see everything dtc resolves
# (includes, path and label overrides elsewhere), so check the table again in
# the DTB the images were built with, as the kernel will read it.
step "Verifying the NOR partition table in the compiled DTB"
DTB="$(find_dtb build_dir)"
python3 "$REPO_ROOT/solarmatrix/openwrt-one-dts.py" check-dtb "$DTB"

# out/ is emptied first so it only ever holds this build's artifacts.
step "Collecting OpenWRT licenses"
reset_out_dir "$OUT_DIR"
OPENWRT_TAG="$TAG" "$REPO_ROOT/solarmatrix/collect-licenses.sh" > "$OUT_DIR/openwrt-licenses.json"

step "Staging firmware artifacts"
stage_artifacts bin/targets "$OUT_DIR" "$VERSION_NUMBER"

printf '%s\n' "$TAG" > "$OUT_DIR/tag.txt"

step "Done — artifacts in $OUT_DIR"

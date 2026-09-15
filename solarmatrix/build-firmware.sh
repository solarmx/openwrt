#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the SolarMatrix firmware from this OpenWRT fork.
# Takes an OpenWRT tag argument -- or the word "latest", which resolves to
# the newest stable upstream release tag -- builds, and emits firmware +
# licenses JSON under solarmatrix/out/.
#
# "latest" is resolved once, up front, and everything downstream sees the
# concrete tag it resolved to: the checkout, the version file, tag.txt and
# the license manifest. A build is therefore still reproducible after the
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
# pollute future builds run outside this script.
trap 'rm -rf "$REPO_ROOT/version" "$REPO_ROOT/files"' EXIT INT TERM

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

# OpenWRT's package/install copies $TOPDIR/files verbatim over the rootfs
# (include/rootfs.mk: prepare_rootfs). That is how the SolarMatrix hardening
# scripts get into the image; the tag checkout above does not carry them, so
# stage them on every build.
step "Staging solarmatrix/files as the rootfs overlay"
cp -a "$REPO_ROOT/solarmatrix/files" "$REPO_ROOT/files"

# build_dir is not cleaned between builds, so a previous build's copy of these
# files would satisfy the post-build check even if this build never applied the
# overlay. Delete them first so only a real application can put them back.
if [ -d build_dir ]; then
    find build_dir -maxdepth 5 \
        \( -path '*/root-*/etc/uci-defaults/99-solarmatrix-hardening' \
        -o -path '*/root-*/sbin/solarmatrix-harden-ssh' \
        -o -path '*/root-*/etc/hotplug.d/block/20-solarmatrix-nvme' \
        -o -path '*/root-*/etc/init.d/solarmatrix-mount' \
        -o -path '*/root-*/etc/init.d/solarmatrix' \
        -o -path '*/root-*/usr/sbin/solarmatrix-storage' \) \
        -delete
fi

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

# The MCP2515 hangs off the mikroBUS SPI bus, which the stock OpenWRT One DTS
# brings up with no child node -- so nothing binds to it and no /dev/spidev
# ever appears. Three edits make it reachable from userspace:
#
#   - UART2 is disabled: its pins collide with SPI1.
#   - The mikrobus-reset gpio-export is dropped, so the controller's userspace
#     driver can own the reset line itself.
#   - A spidev@0 node is added under &spi1. It is declared as silabs,si3210
#     because the kernel spidev driver binds only to the parts listed in
#     spidev_dt_ids and explicitly rejects a generic "spidev" compatible.
#     See OpenWRT PR #17399.
#
# The result is verified below rather than assumed: these are regex edits
# against an upstream file, and a pattern that silently matched nothing would
# otherwise yield firmware with no CAN access and no error anywhere in the log.
step "Patching the OpenWRT One DTS for userspace SPI access"
DTS="target/linux/mediatek/dts/mt7981b-openwrt-one.dts"
if [ ! -f "$DTS" ]; then
    echo "ERROR: DTS not found: $DTS" >&2
    exit 1
fi
python3 - "$DTS" "$TAG" <<'PY'
import re, sys
from pathlib import Path

path, tag = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()

text = re.sub(r'(&uart2\s*\{[^{}]*?status\s*=\s*")okay(";)',
              r'\1disabled\2', text, flags=re.S)
text = re.sub(r'(gpio-export\s*\{[^{}]*)gpio-0\s*\{[^{}]*?\};',
              r'\1', text, flags=re.S)
text = re.sub(r'(&spi1\s*\{[^}]*)(status\s*=\s*"okay";\s*)(\};)',
              r'''\1\2
	spidev@0 {
		compatible = "silabs,si3210";
		reg = <0>;
		#address-cells = <1>;
		#size-cells = <0>;
		spi-max-frequency = <52000000>;
	};
\3''', text, flags=re.S)

path.write_text(text)

problems = []
if "spidev@0" not in text:
    problems.append("spidev@0 node was not added under &spi1")
if "silabs,si3210" not in text:
    problems.append("spidev compatible string is missing")
if "mikrobus-reset" in text:
    problems.append("mikrobus-reset gpio-export was not removed")
if re.search(r'&uart2\s*\{[^{}]*?status\s*=\s*"okay"', text, flags=re.S):
    problems.append("uart2 is still enabled and will collide with SPI1")

if problems:
    sys.stderr.write("ERROR: DTS patch did not apply cleanly to %s:\n" % tag)
    for problem in problems:
        sys.stderr.write("  - %s\n" % problem)
    sys.stderr.write("  The upstream DTS likely changed shape in this release.\n")
    raise SystemExit(1)

print("Verified: spidev@0 added, mikrobus-reset removed, uart2 disabled")
PY

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
printf 'CONFIG_IMAGEOPT=y\n' >> .config
printf 'CONFIG_VERSIONOPT=y\n' >> .config
printf 'CONFIG_VERSION_NUMBER="%s"\n' "$VERSION_NUMBER" >> .config
make defconfig

# defconfig drops unknown symbols without comment, so confirm the packages that
# make this device work are actually selected. A missing kmod-nvme means the SSD
# never appears and /solarmatrix cannot mount; a missing kmod-spi-dev means
# /dev/spidev2.0 never appears and the CAN module is unreachable. Both have
# shipped before, and neither produced an error at build time.
step "Verifying requested packages survived defconfig"
MISSING_PKGS=""
for PKG in kmod-spi-dev kmod-nvme kmod-fs-ext4 parted e2fsprogs \
           blkid curl ca-certificates; do
    if ! grep -q "^CONFIG_PACKAGE_$PKG=y\$" .config; then
        MISSING_PKGS="$MISSING_PKGS $PKG"
    fi
done
if [ -n "$MISSING_PKGS" ]; then
    echo "ERROR: defconfig dropped these packages:$MISSING_PKGS" >&2
    echo "  They are not selectable in this tree -- are the feeds installed?" >&2
    exit 1
fi
echo "Verified: all 8 requested packages are selected"

if ! grep -q "^CONFIG_VERSION_NUMBER=\"$VERSION_NUMBER\"\$" .config; then
    echo "ERROR: defconfig dropped CONFIG_VERSION_NUMBER=\"$VERSION_NUMBER\"" >&2
    echo "  Images would be built as SNAPSHOT rather than as this release." >&2
    exit 1
fi
echo "Verified: release version is $VERSION_NUMBER"

step "Building (this is slow)"
make -j"$(nproc)" V=s

# version.buildinfo now carries the git revision, which is the correct thing
# for it to carry. What matters to a person holding the device is
# DISTRIB_RELEASE, so check that instead -- and check it in the rootfs that
# was actually staged, not in a build variable.
step "Verifying the release version reached the rootfs"
ROOTFS_DIR="$(find build_dir -maxdepth 2 -type d -name 'root-*' | head -1)"
if [ -z "$ROOTFS_DIR" ]; then
    echo "ERROR: no rootfs staging directory under build_dir" >&2
    exit 1
fi
RELEASE_FILE="$ROOTFS_DIR/etc/openwrt_release"
if ! grep -q "^DISTRIB_RELEASE='$VERSION_NUMBER'\$" "$RELEASE_FILE" 2>/dev/null; then
    echo "ERROR: $RELEASE_FILE does not report DISTRIB_RELEASE='$VERSION_NUMBER'" >&2
    grep '^DISTRIB_RELEASE=' "$RELEASE_FILE" 2>/dev/null >&2 || echo "  (no DISTRIB_RELEASE line)" >&2
    exit 1
fi
echo "Verified: DISTRIB_RELEASE='$VERSION_NUMBER'"

# A hardening script that silently failed to reach the rootfs would ship a
# device that answers a root password on the LAN, so make it a build failure
# rather than a surprise in the field. Both files matter: without harden-ssh the
# boot script and the provisioning tool cannot lock the device at all.
# Compared byte for byte, not merely found, so a stale or truncated copy fails.
step "Verifying the hardening overlay reached the rootfs"
ROOTFS_DIR="$(find build_dir -maxdepth 2 -type d -name 'root-*' | head -1)"
if [ -z "$ROOTFS_DIR" ]; then
    echo "ERROR: no rootfs staging directory under build_dir" >&2
    exit 1
fi
for OVERLAY_FILE in \
    etc/uci-defaults/99-solarmatrix-hardening \
    sbin/solarmatrix-harden-ssh \
    etc/hotplug.d/block/20-solarmatrix-nvme \
    etc/init.d/solarmatrix-mount \
    etc/init.d/solarmatrix \
    usr/sbin/solarmatrix-storage \
; do
    if ! cmp -s "$REPO_ROOT/solarmatrix/files/$OVERLAY_FILE" "$ROOTFS_DIR/$OVERLAY_FILE"; then
        echo "ERROR: $OVERLAY_FILE does not match solarmatrix/files/ in the rootfs" >&2
        echo "  Expected: $REPO_ROOT/solarmatrix/files/$OVERLAY_FILE" >&2
        echo "  In rootfs: $ROOTFS_DIR/$OVERLAY_FILE" >&2
        exit 1
    fi
    if [ ! -x "$ROOTFS_DIR/$OVERLAY_FILE" ]; then
        echo "ERROR: $OVERLAY_FILE is not executable in the rootfs" >&2
        exit 1
    fi
    echo "Verified: $ROOTFS_DIR/$OVERLAY_FILE"
done

step "Collecting OpenWRT licenses"
mkdir -p "$OUT_DIR"
OPENWRT_TAG="$TAG" "$REPO_ROOT/solarmatrix/collect-licenses.sh" > "$OUT_DIR/openwrt-licenses.json"

step "Staging firmware artifacts"
# Copy produced firmware images to solarmatrix/out/ so consumers have one dir.
find bin/targets -type f \
    \( -name 'openwrt-*.itb' \
    -o -name 'openwrt-*.ubi' \
    -o -name 'openwrt-*.bin' \
    -o -name 'openwrt-*.img*' \
    -o -name '*.manifest' \
    -o -name 'profiles.json' \
    -o -name 'sha256sums' \) \
    -print -exec cp {} "$OUT_DIR/" \;

printf '%s\n' "$TAG" > "$OUT_DIR/tag.txt"

step "Done — artifacts in $OUT_DIR"

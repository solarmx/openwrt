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

if [ $# -lt 1 ]; then
    echo "usage: $0 <openwrt-tag>|latest" >&2
    echo "Example: $0 v25.12.5" >&2
    echo "         $0 latest      # newest stable upstream release" >&2
    exit 1
fi
TAG="$1"

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
        -o -path '*/root-*/sbin/solarmatrix-harden-ssh' \) \
        -delete
fi

# OpenWRT's scripts/getver.sh checks $TOPDIR/version before its
# commit-counting fallback. Pinning it makes version.buildinfo (and
# /etc/openwrt_release in the rootfs) the literal tag string.
step "Pinning version.buildinfo to $TAG via top-level version file"
echo "$TAG" > "$REPO_ROOT/version"

step "Writing .config for OpenWRT One (mediatek/filogic)"
cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y
EOF
make defconfig

step "Building (this is slow)"
make -j"$(nproc)" V=s

step "Verifying version.buildinfo matches $TAG"
BUILDINFO_FILE="$(find bin/targets -maxdepth 4 -name 'version.buildinfo' | head -1)"
if [ -z "$BUILDINFO_FILE" ]; then
    echo "ERROR: no version.buildinfo emitted by build" >&2
    exit 1
fi
ACTUAL="$(cat "$BUILDINFO_FILE")"
if [ "$ACTUAL" != "$TAG" ]; then
    echo "ERROR: version.buildinfo='$ACTUAL', expected '$TAG'" >&2
    echo "  $BUILDINFO_FILE" >&2
    echo "  Did the version file override fail?" >&2
    exit 1
fi

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
for OVERLAY_FILE in etc/uci-defaults/99-solarmatrix-hardening sbin/solarmatrix-harden-ssh; do
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

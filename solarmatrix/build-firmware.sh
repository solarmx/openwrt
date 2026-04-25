#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the SolarMatrix firmware from this OpenWRT fork.
# Takes an explicit OpenWRT tag argument, builds, and emits
# firmware + licenses JSON under solarmatrix/out/.
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
    echo "usage: $0 <openwrt-tag>" >&2
    echo "Example: $0 v25.12.2" >&2
    exit 1
fi
TAG="$1"

# Refuse to clobber a pre-existing version file. We register the cleanup
# trap only AFTER this check so the trap can never delete a file the
# script didn't create.
if [ -e "$REPO_ROOT/version" ]; then
    echo "ERROR: $REPO_ROOT/version already exists; refusing to overwrite" >&2
    echo "  Remove it manually if it's leftover from a prior failed run." >&2
    exit 1
fi

# Cleanup the top-level 'version' override so it doesn't pollute future
# builds run outside this script.
trap 'rm -f "$REPO_ROOT/version"' EXIT INT TERM

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

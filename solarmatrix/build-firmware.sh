#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the SolarMatrix firmware from this OpenWRT fork.
# Syncs fork from upstream, picks the latest stable tag, builds, and emits
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

# Allow running just the prereq install step.
if [ "${1:-}" = "prereqs" ]; then
    install_prereqs
    exit 0
fi

step "Syncing fork from upstream"
git fetch upstream --tags
git fetch upstream

LATEST_TAG="$(git tag -l 'v*' --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -1)"
if [ -z "$LATEST_TAG" ]; then
    echo "No stable OpenWRT tag found" >&2
    exit 1
fi
step "Latest stable tag: $LATEST_TAG"

# Capture the invoking branch before we detach, so we can overlay solarmatrix/
# from it back onto the tag's tree. This lets the build run AT the upstream
# tag (stable, reproducible) while keeping our GPL build scripts available.
INVOKING_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
if [ -z "$INVOKING_BRANCH" ]; then
    echo "ERROR: refusing to run on detached HEAD." >&2
    echo "Check out a branch containing the solarmatrix/ dir first," >&2
    echo "then re-run this script." >&2
    exit 1
fi

step "Checking out $LATEST_TAG (detached)"
git checkout --detach "$LATEST_TAG"

step "Overlaying solarmatrix/ from $INVOKING_BRANCH"
# Restore the solarmatrix/ dir onto the detached tag's tree. This gives us
# tag's sources + our build scripts. Index will show solarmatrix/ as staged
# but no commit happens.
git checkout "$INVOKING_BRANCH" -- solarmatrix/

step "Writing .config for OpenWRT One (mediatek/filogic)"
cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y
EOF
make defconfig

step "Building (this is slow)"
make -j"$(nproc)" V=s

step "Collecting OpenWRT licenses"
mkdir -p "$OUT_DIR"
OPENWRT_TAG="$LATEST_TAG" "$REPO_ROOT/solarmatrix/collect-licenses.sh" > "$OUT_DIR/openwrt-licenses.json"

step "Staging firmware artifacts"
# OpenWRT's bin/targets/<arch>/<subtarget>/ holds the final images.
find bin/targets -type f \( -name '*.bin' -o -name '*.img' -o -name '*.ipk' \) -print -exec cp {} "$OUT_DIR/" \;
printf '%s\n' "$LATEST_TAG" > "$OUT_DIR/tag.txt"

step "Done — artifacts in $OUT_DIR"

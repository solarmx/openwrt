#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Emits a JSON document listing every package installed in the built rootfs.
# Reads the build's manifest + each package's source Makefile. Packages
# without a PKG_LICENSE are reported as UNKNOWN. License text is resolved
# from the upstream LICENSES/ dir by SPDX ID when available.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${OPENWRT_TAG:-unknown}"

# Find the manifest produced by the build.
MANIFEST="$(find "$REPO_ROOT/bin/targets" -maxdepth 4 -name '*.manifest' 2>/dev/null | head -1)"
if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
    echo '{"generated_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","openwrt_version":"'"$TAG"'","notices":[]}' >&2
    echo "collect-licenses.sh: no manifest found under bin/targets/" >&2
    exit 1
fi

printf '{\n'
printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  "openwrt_version": "%s",\n' "$TAG"
printf '  "notices": [\n'

FIRST=1
while IFS= read -r LINE; do
    # Manifest line: "pkgname - pkgversion"
    PKG="$(printf '%s' "$LINE" | awk -F ' - ' '{print $1}')"
    VER="$(printf '%s' "$LINE" | awk -F ' - ' '{print $2}')"
    [ -z "$PKG" ] && continue

    # Find the Makefile that defines PKG_NAME:=<pkg>. Search package/ and feeds/.
    MK="$(grep -rlE "^PKG_NAME:=${PKG}\$" "$REPO_ROOT/package" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"

    LIC=""
    SRC_URL=""
    if [ -n "$MK" ]; then
        LIC="$(awk -F':=' '/^PKG_LICENSE:=/{print $2; exit}' "$MK" | sed 's/^ *//; s/ *$//')"
        SRC_URL="$(awk -F':=' '/^PKG_SOURCE_URL:=/{print $2; exit}' "$MK" | sed 's/^ *//; s/ *$//')"
    fi
    [ -z "$LIC" ] && LIC="UNKNOWN"

    # Resolve license text from LICENSES/<SPDX> when available.
    LIC_TEXT=""
    if [ "$LIC" != "UNKNOWN" ]; then
        FIRST_SPDX="$(printf '%s' "$LIC" | awk '{print $1}' | tr -d '()')"
        CANDIDATE="$REPO_ROOT/LICENSES/$FIRST_SPDX"
        if [ -f "$CANDIDATE" ]; then
            LIC_TEXT="$(cat "$CANDIDATE")"
        fi
    fi

    [ "$FIRST" -eq 0 ] && printf ',\n'
    FIRST=0
    printf '    {"source":"openwrt","name":%s,"version":%s,"license":%s,"source_url":%s,"text":%s}' \
        "$(printf '%s' "$PKG" | jq -Rs .)" \
        "$(printf '%s' "$VER" | jq -Rs .)" \
        "$(printf '%s' "$LIC" | jq -Rs .)" \
        "$(printf '%s' "$SRC_URL" | jq -Rs .)" \
        "$(printf '%s' "$LIC_TEXT" | jq -Rs .)"
done < "$MANIFEST"

printf '\n  ]\n}\n'

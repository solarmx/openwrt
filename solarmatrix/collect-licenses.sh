#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Emits a JSON document with one notice entry per OpenWRT package installed in
# the built rootfs. Reads PKG_LICENSE and PKG_LICENSE_FILES from each package's
# Makefile. Packages with no PKG_LICENSE are reported as UNKNOWN.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING_DIRS=(build_dir/target-*/root-*/usr/lib/opkg/info)

TAG="${OPENWRT_TAG:-unknown}"

printf '{\n'
printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  "openwrt_version": "%s",\n' "$TAG"
printf '  "notices": [\n'

FIRST=1
for D in "${STAGING_DIRS[@]}"; do
    for CTRL in "$REPO_ROOT/$D"/*.control; do
        [ -f "$CTRL" ] || continue
        PKG="$(awk -F': ' '/^Package:/{print $2; exit}' "$CTRL")"
        VER="$(awk -F': ' '/^Version:/{print $2; exit}' "$CTRL")"

        # Locate the Makefile for this package (first match wins).
        MK="$(grep -rlE "^PKG_NAME:=$PKG\$" "$REPO_ROOT/package" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"
        LIC=""
        if [ -n "$MK" ]; then
            LIC="$(awk -F':=' '/^PKG_LICENSE:=/{print $2; exit}' "$MK" | tr -d ' ')"
        fi
        [ -z "$LIC" ] && LIC="UNKNOWN"

        # Resolve license text from the upstream LICENSES/ dir by SPDX ID.
        # Multi-license expressions (e.g. "GPL-2.0 AND MIT") fall back to the first token.
        LIC_TEXT=""
        if [ -n "$LIC" ] && [ "$LIC" != "UNKNOWN" ]; then
            FIRST_SPDX="$(printf '%s' "$LIC" | awk '{print $1}' | tr -d '()')"
            CANDIDATE="$REPO_ROOT/LICENSES/$FIRST_SPDX"
            if [ -f "$CANDIDATE" ]; then
                LIC_TEXT="$(cat "$CANDIDATE")"
            elif [ -f "$CANDIDATE.txt" ]; then
                LIC_TEXT="$(cat "$CANDIDATE.txt")"
            fi
        fi

        [ "$FIRST" -eq 0 ] && printf ',\n'
        FIRST=0
        printf '    {"source":"openwrt","name":%s,"version":%s,"license":%s,"source_url":"","text":%s}' \
            "$(printf '%s' "$PKG" | jq -Rs .)" \
            "$(printf '%s' "$VER" | jq -Rs .)" \
            "$(printf '%s' "$LIC" | jq -Rs .)" \
            "$(printf '%s' "$LIC_TEXT" | jq -Rs .)"
    done
done

printf '\n  ]\n}\n'

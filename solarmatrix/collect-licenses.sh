#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Emits a JSON document listing every package installed in the built rootfs.
# Reads the build's manifest + each package's source Makefile. Packages
# without a PKG_LICENSE are reported as UNKNOWN. License text is resolved
# per package from its build dir (LICENSE/LICENCE/COPYING/NOTICE files),
# falling back to the upstream LICENSES/<SPDX> template when no per-package
# text exists. Hard fails on licensed packages with no resolvable text.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
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

    # Resolve the Makefile defining this installed package. OpenWRT's installed
    # package names don't map 1:1 to Makefile identifiers, so we try four
    # strategies in order, first hit wins.
    MK=""

    # Strategy 1: Package block match (subpackages like libssl from openssl).
    MK="$(grep -rlE "^define Package/${PKG}\$" "$REPO_ROOT/package" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"

    # Strategy 2: KernelPackage block. kmod-* packages are declared via
    # `define KernelPackage/<stripped-name>`; the installed name carries a
    # `kmod-` prefix that isn't in the macro.
    if [ -z "$MK" ] && case "$PKG" in kmod-*) true;; *) false;; esac; then
        KMOD_NAME="${PKG#kmod-}"
        MK="$(grep -rlE "^define KernelPackage/${KMOD_NAME}\$" "$REPO_ROOT/package/kernel" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"
    fi

    # Strategy 3: PKG_NAME match (legacy exact match).
    if [ -z "$MK" ]; then
        MK="$(grep -rlE "^PKG_NAME:=${PKG}\$" "$REPO_ROOT/package" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"
    fi

    # Strategy 4: ABI-suffix strip (jansson4 -> jansson, libssl3 -> libssl).
    if [ -z "$MK" ]; then
        ABI_STRIPPED="$(printf '%s' "$PKG" | sed -E 's/[0-9]+$//')"
        if [ -n "$ABI_STRIPPED" ] && [ "$ABI_STRIPPED" != "$PKG" ]; then
            MK="$(grep -rlE "^define Package/${ABI_STRIPPED}\$" "$REPO_ROOT/package" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"
            if [ -z "$MK" ]; then
                MK="$(grep -rlE "^PKG_NAME:=${ABI_STRIPPED}\$" "$REPO_ROOT/package" "$REPO_ROOT/feeds" 2>/dev/null | head -1 || true)"
            fi
        fi
    fi

    LIC=""
    SRC_URL=""
    if [ -n "$MK" ]; then
        # Try block-scoped LICENSE (inside `define Package/<PKG>`) first.
        LIC="$(awk -v pkg="$PKG" '
            $0 ~ "^define Package/" pkg "$" { in_block=1; next }
            in_block && /^endef$/ { in_block=0 }
            in_block && /^[[:space:]]*LICENSE[[:space:]]*:=/ {
                sub(/^[[:space:]]*LICENSE[[:space:]]*:=[[:space:]]*/, "")
                print; exit
            }
        ' "$MK" | sed 's/^ *//; s/ *$//')"
        # Fall back to top-level PKG_LICENSE.
        if [ -z "$LIC" ]; then
            LIC="$(awk -F':=' '/^PKG_LICENSE:=/{print $2; exit}' "$MK" | sed 's/^ *//; s/ *$//')"
        fi
        SRC_URL="$(awk -F':=' '/^PKG_SOURCE_URL:=/{print $2; exit}' "$MK" | sed 's/^ *//; s/ *$//')"
    fi
    [ -z "$LIC" ] && LIC="UNKNOWN"

    # Kernel modules that didn't carry an explicit license inherit from the
    # Linux kernel, which is GPL-2.0-only. Label them accordingly.
    if [ "$LIC" = "UNKNOWN" ] && case "$PKG" in kmod-*) true;; *) false;; esac; then
        LIC="GPL-2.0-only"
    fi

    # Resolve license text. Preference order:
    #   1. Real per-package LICENSE/LICENCE/COPYING/NOTICE in the package
    #      build dir (preserves original copyright).
    #   2. SPDX template from $REPO_ROOT/LICENSES/<SPDX> (generic, last resort).
    # Hard fail when $LIC != UNKNOWN and neither source yields text.
    # Accumulate bytes into a temp file so trailing newlines are preserved
    # byte-for-byte (bash $(cat ...) strips them).
    LIC_TMP="$(mktemp)"
    FIRST_SPDX="$(printf '%s' "$LIC" | awk '{print $1}' | tr -d '()')"

    # Build dirs have layout build_dir/target-<arch>/<PKG_NAME>-<version>/.
    BUILD_MATCH=""
    for BD in "$REPO_ROOT"/build_dir/target-*/"$PKG-$VER" \
              "$REPO_ROOT"/build_dir/target-*/"$PKG"-*; do
        [ -d "$BD" ] || continue
        BUILD_MATCH="$BD"
        break
    done
    FIRST_FILE=1
    if [ -n "$BUILD_MATCH" ]; then
        while IFS= read -r F; do
            if [ "$FIRST_FILE" -eq 0 ]; then
                printf '\n\n---\n\n' >> "$LIC_TMP"
            fi
            cat "$F" >> "$LIC_TMP"
            FIRST_FILE=0
        done < <(find "$BUILD_MATCH" -maxdepth 2 -type f \
            \( -iname 'LICENSE*' -o -iname 'LICENCE*' \
               -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
            | sort)
    fi

    # Fallback: SPDX template (generic, only when no per-package LICENSE found).
    if [ "$FIRST_FILE" -eq 1 ] && [ "$LIC" != "UNKNOWN" ]; then
        CANDIDATE="$REPO_ROOT/LICENSES/$FIRST_SPDX"
        if [ -f "$CANDIDATE" ]; then
            cat "$CANDIDATE" >> "$LIC_TMP"
            FIRST_FILE=0
        fi
    fi

    # Hard fail: licensed package with no resolvable text.
    if [ "$FIRST_FILE" -eq 1 ] && [ "$LIC" != "UNKNOWN" ]; then
        rm -f "$LIC_TMP"
        echo "collect-licenses.sh: $PKG@$VER: license=$LIC but no LICENSE text found" >&2
        echo "  searched: $REPO_ROOT/build_dir/target-*/$PKG-*/{LICENSE,LICENCE,COPYING,NOTICE}*" >&2
        echo "  searched: $REPO_ROOT/LICENSES/$FIRST_SPDX" >&2
        exit 1
    fi

    [ "$FIRST" -eq 0 ] && printf ',\n'
    FIRST=0
    printf '    {"source":"openwrt","name":%s,"version":%s,"license":%s,"source_url":%s,"text":%s}' \
        "$(printf '%s' "$PKG" | jq -Rs .)" \
        "$(printf '%s' "$VER" | jq -Rs .)" \
        "$(printf '%s' "$LIC" | jq -Rs .)" \
        "$(printf '%s' "$SRC_URL" | jq -Rs .)" \
        "$(jq -Rs . < "$LIC_TMP")"
    rm -f "$LIC_TMP"
done < "$MANIFEST"

printf '\n  ]\n}\n'

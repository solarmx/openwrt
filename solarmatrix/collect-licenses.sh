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

LIC_TMP=""
trap '[ -n "${LIC_TMP:-}" ] && rm -f "$LIC_TMP"' EXIT INT TERM

# REPO_ROOT is overridable so tests can point the script at a synthetic tree.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TAG="${OPENWRT_TAG:-unknown}"

# Find the manifest produced by the build.
MANIFEST="$(find "$REPO_ROOT/bin/targets" -maxdepth 4 -name '*.manifest' 2>/dev/null | head -1)"
if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
    echo '{"generated_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","openwrt_version":"'"$TAG"'","notices":[]}' >&2
    echo "collect-licenses.sh: no manifest found under bin/targets/" >&2
    exit 1
fi

# Single tempfile reused across all iterations — avoids leaking N-1 tempfiles
# per run. Trap at top of script handles cleanup on exit.
LIC_TMP="$(mktemp)"

# Buffer notices as per-entry JSON strings so post-passes (ucode-mod-*
# inheritance, vendor-firmware override injection) can rewrite entries
# before we emit the final document.
NOTICES=()

while IFS= read -r LINE; do
    # Manifest line: "pkgname - pkgversion"
    PKG="$(printf '%s' "$LINE" | awk -F ' - ' '{print $1}')"
    VER="$(printf '%s' "$LINE" | awk -F ' - ' '{print $2}')"
    [ -z "$PKG" ] && continue
    : > "$LIC_TMP"

    # Resolve the Makefile defining this installed package. OpenWRT's installed
    # package names don't map 1:1 to Makefile identifiers, so we try four
    # strategies in order, first hit wins.
    MK=""
    ABI_STRIPPED=""

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

    # Makefile-declared PKG_NAME drives build_dir lookups for pkgs whose
    # installed name was ABI-stripped or otherwise diverges from source.
    MK_PKG_NAME=""
    if [ -n "$MK" ]; then
        MK_PKG_NAME="$(awk -F':=' '/^PKG_NAME[[:space:]]*:=/{print $2; exit}' "$MK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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
    FIRST_SPDX="$(printf '%s' "$LIC" | awk '{print $1}' | tr -d '()')"

    # Build dirs have layout build_dir/target-<arch>/<PKG_NAME>-<version>/.
    # Installed name may differ from the source dir (ABI-stripped, Makefile-
    # declared). Try each candidate, first hit wins. Match exactly on
    # "<CAND>-<VER>" — prefix wildcards silently match longer-named neighbors
    # (e.g. foo-utils-9.9 when looking for foo-1.0), causing misattribution.
    BUILD_MATCH=""
    for CAND in "$PKG" "${ABI_STRIPPED:-}" "$MK_PKG_NAME"; do
        [ -n "$CAND" ] || continue
        for BD in "$REPO_ROOT"/build_dir/target-*/"$CAND-$VER"; do
            [ -d "$BD" ] || continue
            BUILD_MATCH="$BD"
            break 2
        done
    done
    if [ -n "$BUILD_MATCH" ]; then
        while IFS= read -r F; do
            [ -s "$LIC_TMP" ] && printf '\n\n---\n\n' >> "$LIC_TMP"
            cat "$F" >> "$LIC_TMP"
        done < <(find "$BUILD_MATCH" -maxdepth 2 -type f \
            \( -iname 'LICENSE*' -o -iname 'LICENCE*' \
               -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
            | sort)
    fi

    # Fallback: SPDX template (generic, only when no per-package LICENSE found).
    if [ ! -s "$LIC_TMP" ] && [ "$LIC" != "UNKNOWN" ]; then
        CANDIDATE="$REPO_ROOT/LICENSES/$FIRST_SPDX"
        if [ -f "$CANDIDATE" ]; then
            cat "$CANDIDATE" >> "$LIC_TMP"
        fi
    fi

    # Hard fail: licensed package with no resolvable text.
    if [ ! -s "$LIC_TMP" ] && [ "$LIC" != "UNKNOWN" ]; then
        SEARCHED_NAMES="$PKG"
        [ -n "${ABI_STRIPPED:-}" ] && SEARCHED_NAMES="$SEARCHED_NAMES, $ABI_STRIPPED"
        [ -n "${MK_PKG_NAME:-}" ] && [ "$MK_PKG_NAME" != "$PKG" ] && SEARCHED_NAMES="$SEARCHED_NAMES, $MK_PKG_NAME"
        echo "collect-licenses.sh: $PKG@$VER: license=$LIC but no LICENSE text found" >&2
        echo "  searched: $REPO_ROOT/build_dir/target-*/{$SEARCHED_NAMES}-$VER/{LICENSE,LICENCE,COPYING,NOTICE}*" >&2
        echo "  searched: $REPO_ROOT/LICENSES/$FIRST_SPDX" >&2
        exit 1
    fi

    ENTRY="$(jq -cn \
        --arg pkg "$PKG" \
        --arg ver "$VER" \
        --arg lic "$LIC" \
        --arg src "$SRC_URL" \
        --rawfile text "$LIC_TMP" \
        '{source:"openwrt", name:$pkg, version:$ver, license:$lic, source_url:$src, text:$text}')"
    NOTICES+=("$ENTRY")
done < "$MANIFEST"

# Assemble final document. Buffered notices array feeds jq -s to produce a
# single JSON array, then combined with header fields.
if [ "${#NOTICES[@]}" -eq 0 ]; then
    NOTICES_JSON='[]'
else
    NOTICES_JSON="$(printf '%s\n' "${NOTICES[@]}" | jq -s .)"
fi
jq -n \
    --argjson notices "$NOTICES_JSON" \
    --arg gen_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tag "$TAG" \
    '{generated_at:$gen_at, openwrt_version:$tag, notices:$notices}'

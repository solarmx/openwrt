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

    # Build dirs usually have layout build_dir/target-<arch>/<PKG_NAME>-<version>/.
    # Installed name may differ from the source dir (ABI-stripped, Makefile-
    # declared). Try each candidate, first hit wins. Match exactly on
    # "<CAND>-<VER>" — prefix wildcards silently match longer-named neighbors
    # (e.g. foo-utils-9.9 when looking for foo-1.0), causing misattribution.
    #
    # Bare-CAND fallback: some packages (apk-mbedtls and siblings) use a
    # version-less outer dir named after PKG_NAME, containing a nested
    # upstream-tarball dir (e.g. apk-mbedtls/apk-3.0.5/LICENSE). Tried only
    # after the versioned glob misses; bare-CAND is an EXACT dir-name match
    # (no trailing *), so `foo` does not silently match `foo-utils`.
    # OpenWRT manifests emit "<PKG_VERSION>-r<PKG_RELEASE>" but build_dir
    # paths use only PKG_VERSION. Strip trailing "-r<digits>" so the
    # versioned glob matches the real on-disk dir.
    if [[ "$VER" =~ ^(.*)-r[0-9]+$ ]]; then
        VER_STRIPPED="${BASH_REMATCH[1]}"
    else
        VER_STRIPPED="$VER"
    fi

    BUILD_MATCH=""
    for CAND in "$PKG" "${ABI_STRIPPED:-}" "$MK_PKG_NAME"; do
        [ -n "$CAND" ] || continue
        for BD in "$REPO_ROOT"/build_dir/target-*/"$CAND-$VER" \
                  "$REPO_ROOT"/build_dir/target-*/"$CAND-$VER_STRIPPED" \
                  "$REPO_ROOT"/build_dir/target-*/"$CAND"; do
            [ -d "$BD" ] || continue
            BUILD_MATCH="$BD"
            break 2
        done
    done

    # Makefile-parent-dir fallback: in-tree utilities (e.g. fitblk) are simple
    # enough that OpenWRT never stages them under build_dir/target-*/. When no
    # build_dir match exists but we did resolve a Makefile, look for LICENSE-
    # like files alongside the Makefile itself.
    if [ -z "$BUILD_MATCH" ] && [ -n "$MK" ]; then
        MK_DIR="$(dirname "$MK")"
        if [ -d "$MK_DIR" ]; then
            BUILD_MATCH="$MK_DIR"
        fi
    fi

    if [ -n "$BUILD_MATCH" ]; then
        while IFS= read -r F; do
            [ -s "$LIC_TMP" ] && printf '\n\n---\n\n' >> "$LIC_TMP"
            cat "$F" >> "$LIC_TMP"
        done < <(find "$BUILD_MATCH" -maxdepth 3 -type f \
            \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' \
               -o -iname 'NOTICE*' -o -iname 'copyright*' -o -iname 'LEGAL*' \) \
            | sort)
    fi

    # Fallback: SPDX template (generic, only when no per-package LICENSE found).
    # Try the exact SPDX id first, then strip -only / -or-later suffixes.
    # OpenWRT's LICENSES/ dir ships base names (e.g. GPL-2.0) while modern
    # Makefiles declare the disambiguated SPDX form (GPL-2.0-only,
    # GPL-2.0-or-later). OpenWRT's own top-level COPYING treats these as
    # aliases of the base license, so stripping matches upstream intent.
    # Parameter expansion "${VAR%-suffix}" is a no-op when the suffix is
    # absent (MIT stays MIT), so the loop is safe for any SPDX id.
    if [ ! -s "$LIC_TMP" ] && [ "$LIC" != "UNKNOWN" ]; then
        for SPDX_TRY in "$FIRST_SPDX" "${FIRST_SPDX%-only}" "${FIRST_SPDX%-or-later}"; do
            CANDIDATE="$REPO_ROOT/LICENSES/$SPDX_TRY"
            if [ -f "$CANDIDATE" ]; then
                cat "$CANDIDATE" >> "$LIC_TMP"
                break
            fi
        done
    fi

    # Hard fail: licensed package with no resolvable text.
    if [ ! -s "$LIC_TMP" ] && [ "$LIC" != "UNKNOWN" ]; then
        SEARCHED_NAMES="$PKG"
        [ -n "${ABI_STRIPPED:-}" ] && SEARCHED_NAMES="$SEARCHED_NAMES, $ABI_STRIPPED"
        [ -n "${MK_PKG_NAME:-}" ] && [ "$MK_PKG_NAME" != "$PKG" ] && SEARCHED_NAMES="$SEARCHED_NAMES, $MK_PKG_NAME"
        SEARCHED_VERS="$VER"
        [ "$VER_STRIPPED" != "$VER" ] && SEARCHED_VERS="$SEARCHED_VERS, $VER_STRIPPED"
        echo "collect-licenses.sh: $PKG@$VER: license=$LIC but no LICENSE text found" >&2
        echo "  searched: $REPO_ROOT/build_dir/target-*/{$SEARCHED_NAMES}-{$SEARCHED_VERS}/{LICENSE,LICENCE,COPYING,NOTICE,copyright,LEGAL}*" >&2
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

# ucode-mod-* inheritance: upstream OpenWRT omits PKG_LICENSE on these
# subpackages even though they build from the same tree as `ucode` (ISC).
# Inherit license=ISC and text from the parent `ucode` notice. Hard fail
# if parent is missing or its text is empty — shipping an unattributed
# subpackage is worse than failing the build.
UCODE_TEXT=""
for ENTRY in "${NOTICES[@]}"; do
    NAME=$(printf '%s' "$ENTRY" | jq -r .name)
    if [ "$NAME" = "ucode" ]; then
        UCODE_TEXT=$(printf '%s' "$ENTRY" | jq -r .text)
        break
    fi
done

NEW_NOTICES=()
for ENTRY in "${NOTICES[@]}"; do
    NAME=$(printf '%s' "$ENTRY" | jq -r .name)
    case "$NAME" in
        ucode-mod-*)
            if [ -z "$UCODE_TEXT" ]; then
                echo "collect-licenses.sh: $NAME: parent 'ucode' missing or has empty text" >&2
                exit 1
            fi
            ENTRY=$(printf '%s' "$ENTRY" | jq --arg t "$UCODE_TEXT" \
                '.license="ISC" | .text=$t')
            ;;
    esac
    NEW_NOTICES+=("$ENTRY")
done
NOTICES=("${NEW_NOTICES[@]}")

# Vendor-firmware override injection. Second post-pass, runs after ucode
# inheritance so an override can still intentionally re-label a ucode-mod-*
# entry if that ever becomes necessary. For each notice, if
# solarmatrix/licenses/vendor-firmware/<name>.{txt,license} both exist, the
# override wins over any other text/license resolution. Half-pair is a hard
# fail — shipping one file without the other is always a commit mistake.
OVERRIDE_DIR="$REPO_ROOT/solarmatrix/licenses/vendor-firmware"
NEW_NOTICES=()
for ENTRY in "${NOTICES[@]}"; do
    NAME=$(printf '%s' "$ENTRY" | jq -r .name)
    OV_TXT="$OVERRIDE_DIR/$NAME.txt"
    OV_LIC="$OVERRIDE_DIR/$NAME.license"
    if [ -f "$OV_TXT" ] && [ -f "$OV_LIC" ]; then
        OV_LIC_ID=$(head -n1 "$OV_LIC" | tr -d '\r\n' | awk '{$1=$1};1')
        ENTRY=$(jq -cn --arg l "$OV_LIC_ID" --rawfile t "$OV_TXT" \
            --argjson base "$ENTRY" \
            '$base | .license=$l | .text=$t')
    elif [ -f "$OV_TXT" ] && [ ! -f "$OV_LIC" ]; then
        echo "collect-licenses.sh: $NAME: found $OV_TXT but missing $OV_LIC" >&2
        exit 1
    elif [ ! -f "$OV_TXT" ] && [ -f "$OV_LIC" ]; then
        echo "collect-licenses.sh: $NAME: found $OV_LIC but missing $OV_TXT" >&2
        exit 1
    fi
    NEW_NOTICES+=("$ENTRY")
done
NOTICES=("${NEW_NOTICES[@]}")

# Final gate: every notice must have non-empty text AND non-empty,
# non-UNKNOWN license. Collect ALL offenders before exiting — a single run
# should tell the operator every entry they need to fix, not just the first.
BAD_LINES=()
for ENTRY in "${NOTICES[@]}"; do
    NAME=$(printf '%s' "$ENTRY" | jq -r .name)
    LICVAL=$(printf '%s' "$ENTRY" | jq -r .license)
    TXTVAL=$(printf '%s' "$ENTRY" | jq -r .text)
    if [ -z "$LICVAL" ] || [ "$LICVAL" = "UNKNOWN" ]; then
        DISP_LIC="${LICVAL:-<empty>}"
        BAD_LINES+=("$NAME: license=$DISP_LIC. Create $OVERRIDE_DIR/$NAME.{txt,license} override.")
    fi
    if [ -z "$TXTVAL" ]; then
        BAD_LINES+=("$NAME: text empty. Create $OVERRIDE_DIR/$NAME.{txt,license} override.")
    fi
done
if [ "${#BAD_LINES[@]}" -gt 0 ]; then
    echo "collect-licenses.sh: bad license metadata:" >&2
    for LINE in "${BAD_LINES[@]}"; do
        echo "  $LINE" >&2
    done
    exit 1
fi

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

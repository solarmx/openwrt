#!/bin/bash
# Table-driven tests for solarmatrix/collect-licenses.sh.
# Each test case sets up a synthetic OpenWRT tree under $TMPDIR, sets
# REPO_ROOT to that tree, runs collect-licenses.sh, and asserts on output.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/collect-licenses.sh"

FAIL=0
CASES=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $msg"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *)
            echo "FAIL: $msg"
            echo "  needle:   $needle"
            echo "  haystack: $haystack"
            FAIL=$((FAIL + 1))
            ;;
    esac
}

# --- Case 1: package with LICENSE in $PKG_BUILD_DIR emits text = file bytes ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-mips_24kc_musl/foo-1.0" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=MIT
MK
cat > "$T/build_dir/target-mips_24kc_musl/foo-1.0/LICENSE" <<'LIC'
MIT License

Copyright (c) 2025 Example Copyright Holder
Permission is hereby granted, free of charge, ...
LIC
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 1: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="foo") | .text')
LICVAL=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="foo") | .license')
assert_contains 'Copyright (c) 2025 Example Copyright Holder' "$TEXT" \
    "case 1: per-package LICENSE bytes appear in text"
assert_eq 'MIT' "$LICVAL" "case 1: MIT license carried through"
rm -rf "$T"

# --- Case 2: LICENSE + COPYING concat with separator, sort order ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/bar" "$T/build_dir/target-x/bar-2.0" "$T/bin/targets/x/y"
cat > "$T/package/bar/Makefile" <<'MK'
define Package/bar
endef
PKG_NAME:=bar
PKG_LICENSE:=BSD-3-Clause
MK
printf 'LICENSE-FIRST\n' > "$T/build_dir/target-x/bar-2.0/LICENSE"
printf 'COPYING-SECOND\n' > "$T/build_dir/target-x/bar-2.0/COPYING"
printf 'bar - 2.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 2: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="bar") | .text')
# COPYING sorts before LICENSE alphabetically. Expect COPYING bytes, then
# separator "\n\n---\n\n", then LICENSE bytes. Each source file ends with
# its own trailing newline from printf '...\n'.
EXPECTED=$'COPYING-SECOND\n\n\n---\n\nLICENSE-FIRST'
assert_eq "$EXPECTED" "$TEXT" "case 2: COPYING then separator then LICENSE"
rm -rf "$T"

# --- Case 3: licensed package with no LICENSE anywhere = hard fail ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/baz" "$T/build_dir/target-x/baz-3.0" "$T/bin/targets/x/y"
cat > "$T/package/baz/Makefile" <<'MK'
define Package/baz
endef
PKG_NAME:=baz
PKG_LICENSE:=ISC
MK
# No LICENSE file anywhere, no LICENSES/ISC template.
printf 'baz - 3.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
if OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1); then
    echo "FAIL: case 3: expected nonzero exit, got 0"
    FAIL=$((FAIL + 1))
else
    assert_contains "baz@3.0: license=ISC but no LICENSE text found" "$OUT" \
        "case 3: stderr names package + license"
fi
rm -rf "$T"

# --- Case 4: SPDX-template fallback works when no per-package LICENSE ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/qux" "$T/build_dir/target-x/qux-1.0" "$T/bin/targets/x/y" "$T/LICENSES"
cat > "$T/package/qux/Makefile" <<'MK'
define Package/qux
endef
PKG_NAME:=qux
PKG_LICENSE:=GPL-2.0-only
MK
# No per-package LICENSE; SPDX template exists.
cat > "$T/LICENSES/GPL-2.0-only" <<'TPL'
GNU GENERAL PUBLIC LICENSE
Version 2, June 1991 (generic SPDX template body)
TPL
printf 'qux - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 4: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="qux") | .text')
assert_contains 'GNU GENERAL PUBLIC LICENSE' "$TEXT" \
    "case 4: SPDX template used when no per-package LICENSE"
assert_contains 'Version 2, June 1991 (generic SPDX template body)' "$TEXT" \
    "case 4: SPDX template body present"
rm -rf "$T"

# --- Case 5: license=UNKNOWN + empty text still allowed at F1 stage ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/bin/targets/x/y"
# No package/Makefile entry, no LICENSE file -> license=UNKNOWN, text="".
printf 'mystery - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 5: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
LICVAL=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="mystery") | .license')
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="mystery") | .text')
assert_eq 'UNKNOWN' "$LICVAL" "case 5: UNKNOWN license preserved"
assert_eq '' "$TEXT" "case 5: empty text preserved (gate lands in F3)"
rm -rf "$T"

# --- Case 6: ABI-stripped package walks build_dir for real LICENSE, not SPDX template ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/jansson" "$T/build_dir/target-x/jansson-2.14" \
         "$T/bin/targets/x/y" "$T/LICENSES"
cat > "$T/package/jansson/Makefile" <<'MK'
define Package/jansson
endef
PKG_NAME:=jansson
PKG_LICENSE:=MIT
MK
printf 'MIT template body\n' > "$T/LICENSES/MIT"
printf 'REAL JANSSON COPYRIGHT 2009 P.L.\n' > "$T/build_dir/target-x/jansson-2.14/LICENSE"
printf 'jansson4 - 2.14\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 6: nonzero exit $RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="jansson4") | .text')
assert_contains "REAL JANSSON COPYRIGHT 2009 P.L." "$TEXT" \
    "case 6: ABI-stripped jansson4 picks real LICENSE from jansson-2.14/, not SPDX template"
case "$TEXT" in
    *"MIT template body"*)
        echo "FAIL: case 6: text contains SPDX template bytes (attribution regression)"
        FAIL=$((FAIL + 1))
        ;;
esac
rm -rf "$T"

# --- Case 7: zero-byte LICENSE with license!=UNKNOWN still hard-fails ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-x/foo-1.0" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=MIT
MK
: > "$T/build_dir/target-x/foo-1.0/LICENSE"   # zero-byte
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1) || RC=$?
[ $RC -ne 0 ] || { echo "FAIL: case 7: zero-byte LICENSE should hard-fail"; FAIL=$((FAIL+1)); }
assert_contains "foo@1.0: license=MIT but no LICENSE text found" "$OUT" \
    "case 7: stderr names pkg + license"
rm -rf "$T"

# --- Case 8: prefix glob must NOT match longer-named neighbor package ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-x/foo-utils-9.9" \
         "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=MIT
MK
printf 'WRONG_PACKAGE_FOO_UTILS_LICENSE\n' > "$T/build_dir/target-x/foo-utils-9.9/LICENSE"
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1) || RC=$?
[ $RC -ne 0 ] || { echo "FAIL: case 8: expected hard-fail, got RC=0"; FAIL=$((FAIL+1)); }
case "$OUT" in
    *"WRONG_PACKAGE_FOO_UTILS_LICENSE"*)
        echo "FAIL: case 8: emitted neighbor package's LICENSE (misattribution)"
        FAIL=$((FAIL + 1))
        ;;
esac
assert_contains "foo@1.0: license=MIT but no LICENSE text found" "$OUT" \
    "case 8: stderr names pkg + license on hard-fail"
rm -rf "$T"

echo "--- $CASES cases, $FAIL failures ---"
[ "$FAIL" -eq 0 ]

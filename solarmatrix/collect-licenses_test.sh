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

# --- Case 5: [retired at F3] license=UNKNOWN + empty text is now a hard-fail.
# Coverage moved to case 14 (same setup, asserts nonzero exit + stderr content).

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

# --- Case 9: ucode-mod-fs inherits ISC + text from ucode parent ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/ucode" "$T/build_dir/target-x/ucode-2026.01" "$T/bin/targets/x/y"
cat > "$T/package/ucode/Makefile" <<'MK'
define Package/ucode
endef
PKG_NAME:=ucode
PKG_LICENSE:=ISC
MK
cat > "$T/build_dir/target-x/ucode-2026.01/LICENSE" <<'LIC'
ISC License — Copyright (c) 2020+ jow@
Permission to use, copy, modify, ...
LIC
# Subpackage ucode-mod-fs has no Makefile entry (simulates upstream gap).
printf 'ucode - 2026.01\nucode-mod-fs - 2026.01\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 9: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
MOD_LIC=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ucode-mod-fs") | .license')
MOD_TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ucode-mod-fs") | .text')
PARENT_TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ucode") | .text')
assert_eq "ISC" "$MOD_LIC" "case 9: ucode-mod-fs license=ISC inherited"
assert_eq "$PARENT_TEXT" "$MOD_TEXT" \
    "case 9: ucode-mod-fs text byte-identical to ucode parent"
assert_contains "ISC License — Copyright (c) 2020+ jow@" "$MOD_TEXT" \
    "case 9: inherited text is the real parent LICENSE bytes"
rm -rf "$T"

# --- Case 10: multiple ucode-mod-* subpackages all inherit ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/ucode" "$T/build_dir/target-x/ucode-2026.01" "$T/bin/targets/x/y"
cat > "$T/package/ucode/Makefile" <<'MK'
define Package/ucode
endef
PKG_NAME:=ucode
PKG_LICENSE:=ISC
MK
printf 'UCODE PARENT LICENSE BYTES\n' > "$T/build_dir/target-x/ucode-2026.01/LICENSE"
printf 'ucode - 2026.01\nucode-mod-fs - 2026.01\nucode-mod-uloop - 2026.01\nucode-mod-uci - 2026.01\n' \
    > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 10: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
for SUB in ucode-mod-fs ucode-mod-uloop ucode-mod-uci; do
    SUB_LIC=$(printf '%s' "$OUT" | jq -r --arg n "$SUB" '.notices[] | select(.name==$n) | .license')
    SUB_TEXT=$(printf '%s' "$OUT" | jq -r --arg n "$SUB" '.notices[] | select(.name==$n) | .text')
    assert_eq "ISC" "$SUB_LIC" "case 10: $SUB license=ISC inherited"
    assert_contains "UCODE PARENT LICENSE BYTES" "$SUB_TEXT" \
        "case 10: $SUB text inherited from ucode parent"
done
rm -rf "$T"

# --- Case 11: ucode-mod-fs without ucode parent = hard fail ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/bin/targets/x/y"
# Manifest has ucode-mod-fs but no ucode parent entry.
printf 'ucode-mod-fs - 2026.01\n' > "$T/bin/targets/x/y/rootfs.manifest"
if OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1); then
    echo "FAIL: case 11: expected nonzero exit, got 0"
    FAIL=$((FAIL + 1))
else
    assert_contains "ucode-mod-fs: parent 'ucode' missing or has empty text" "$OUT" \
        "case 11: stderr names failing subpackage + missing parent"
fi
rm -rf "$T"

# --- Case 12: non-matching names ("ucodebro") untouched by inheritance rule ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/ucode" "$T/build_dir/target-x/ucode-2026.01" \
         "$T/package/ucodebro" "$T/build_dir/target-x/ucodebro-1.0" \
         "$T/bin/targets/x/y"
cat > "$T/package/ucode/Makefile" <<'MK'
define Package/ucode
endef
PKG_NAME:=ucode
PKG_LICENSE:=ISC
MK
printf 'UCODE PARENT LICENSE\n' > "$T/build_dir/target-x/ucode-2026.01/LICENSE"
cat > "$T/package/ucodebro/Makefile" <<'MK'
define Package/ucodebro
endef
PKG_NAME:=ucodebro
PKG_LICENSE:=Apache-2.0
MK
printf 'UCODEBRO OWN LICENSE BYTES\n' > "$T/build_dir/target-x/ucodebro-1.0/LICENSE"
printf 'ucode - 2026.01\nucodebro - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 12: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
BRO_LIC=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ucodebro") | .license')
BRO_TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ucodebro") | .text')
assert_eq "Apache-2.0" "$BRO_LIC" \
    "case 12: ucodebro keeps own license (name doesn't match ucode-mod-* pattern)"
assert_contains "UCODEBRO OWN LICENSE BYTES" "$BRO_TEXT" \
    "case 12: ucodebro keeps own LICENSE text"
case "$BRO_TEXT" in
    *"UCODE PARENT LICENSE"*)
        echo "FAIL: case 12: ucodebro inherited from ucode (should not have)"
        FAIL=$((FAIL + 1))
        ;;
esac
rm -rf "$T"

# --- Case 13: vendor-firmware override (.txt + .license) applied ---
# No Makefile entry, so LIC would otherwise stay UNKNOWN. Override pair wins.
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/bin/targets/x/y" "$T/solarmatrix/licenses/vendor-firmware"
printf 'vendor terms\n' > "$T/solarmatrix/licenses/vendor-firmware/my-blob.txt"
printf 'Proprietary-MyVendor-Firmware\n' > "$T/solarmatrix/licenses/vendor-firmware/my-blob.license"
printf 'my-blob - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 13: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
LICVAL=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="my-blob") | .license')
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="my-blob") | .text')
assert_eq "Proprietary-MyVendor-Firmware" "$LICVAL" \
    "case 13: license taken from override .license file"
assert_contains "vendor terms" "$TEXT" \
    "case 13: text taken from override .txt file"
rm -rf "$T"

# --- Case 14: license=UNKNOWN + no override = hard fail naming override paths ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/bin/targets/x/y"
# No package/Makefile entry + no override => license=UNKNOWN survives.
printf 'mystery - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
if OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1); then
    echo "FAIL: case 14: expected nonzero exit, got 0"
    FAIL=$((FAIL + 1))
else
    assert_contains "mystery" "$OUT" "case 14: stderr names package"
    assert_contains "solarmatrix/licenses/vendor-firmware/mystery.{txt,license}" "$OUT" \
        "case 14: stderr names expected override paths"
fi
rm -rf "$T"

# --- Case 15: override .txt present but .license missing = hard fail ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/bin/targets/x/y" "$T/solarmatrix/licenses/vendor-firmware"
printf 'lone text\n' > "$T/solarmatrix/licenses/vendor-firmware/lone.txt"
# No lone.license sibling.
printf 'lone - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
if OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1); then
    echo "FAIL: case 15: expected nonzero exit, got 0"
    FAIL=$((FAIL + 1))
else
    assert_contains "lone.license" "$OUT" "case 15: stderr names the missing .license sibling"
fi
rm -rf "$T"

# --- Case 16: override wins over MIT + real LICENSE in build_dir ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-x/foo-1.0" \
         "$T/bin/targets/x/y" "$T/solarmatrix/licenses/vendor-firmware"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=MIT
MK
printf 'REAL BUILD_DIR LICENSE BYTES\n' > "$T/build_dir/target-x/foo-1.0/LICENSE"
printf 'OVERRIDE WINS TEXT\n' > "$T/solarmatrix/licenses/vendor-firmware/foo.txt"
printf 'Proprietary-Override\n' > "$T/solarmatrix/licenses/vendor-firmware/foo.license"
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 16: nonzero exit $RC"; FAIL=$((FAIL + 1)); }
LICVAL=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="foo") | .license')
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="foo") | .text')
assert_eq "Proprietary-Override" "$LICVAL" \
    "case 16: override license wins over PKG_LICENSE=MIT"
assert_contains "OVERRIDE WINS TEXT" "$TEXT" \
    "case 16: override text wins over build_dir LICENSE bytes"
case "$TEXT" in
    *"REAL BUILD_DIR LICENSE BYTES"*)
        echo "FAIL: case 16: text still carries build_dir bytes (override not applied)"
        FAIL=$((FAIL + 1))
        ;;
esac
rm -rf "$T"

# --- Case 17: final gate catches override that smuggles UNKNOWN in .license ---
# An override .license containing literal "UNKNOWN" is an override-author mistake;
# final gate must still reject it (defense in depth — gate is last line of defense).
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/bin/targets/x/y" "$T/solarmatrix/licenses/vendor-firmware"
printf 'some terms\n' > "$T/solarmatrix/licenses/vendor-firmware/sneaky.txt"
printf 'UNKNOWN\n' > "$T/solarmatrix/licenses/vendor-firmware/sneaky.license"
printf 'sneaky - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
if OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1); then
    echo "FAIL: case 17: expected nonzero exit, got 0"
    FAIL=$((FAIL + 1))
else
    assert_contains "sneaky" "$OUT" "case 17: final gate names offender"
    assert_contains "UNKNOWN" "$OUT" "case 17: gate reports license=UNKNOWN"
fi
rm -rf "$T"

echo "--- $CASES cases, $FAIL failures ---"
[ "$FAIL" -eq 0 ]

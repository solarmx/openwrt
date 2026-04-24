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

# --- Case 18: apk-variant packages use version-less outer dir with nested upstream ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/apk-mbedtls" "$T/build_dir/target-x/apk-mbedtls/apk-3.0.5" "$T/bin/targets/x/y"
cat > "$T/package/apk-mbedtls/Makefile" <<'MK'
define Package/apk-mbedtls
endef
PKG_NAME:=apk-mbedtls
PKG_LICENSE:=GPL-2.0-only
MK
printf 'REAL APK LICENSE TEXT\n' > "$T/build_dir/target-x/apk-mbedtls/apk-3.0.5/LICENSE"
printf 'apk-mbedtls - 3.0.5-r2\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 18: nonzero exit $RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[]? | select(.name=="apk-mbedtls") | .text')
assert_contains "REAL APK LICENSE TEXT" "$TEXT" \
    "case 18: apk-mbedtls finds nested LICENSE under apk-3.0.5/"
rm -rf "$T"

# --- Case 19: bare CAND fallback still requires exact dir name match (no prefix glob) ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-x/foo-utils" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=MIT
MK
printf 'NEIGHBOR CONTENT NOT FOO\n' > "$T/build_dir/target-x/foo-utils/LICENSE"
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>&1) || RC=$?
[ $RC -ne 0 ] || { echo "FAIL: case 19: bare CAND must not match foo-utils as foo"; FAIL=$((FAIL+1)); }
case "$OUT" in
    *"NEIGHBOR CONTENT NOT FOO"*) echo "FAIL: case 19: emitted neighbor LICENSE"; FAIL=$((FAIL+1));;
esac
rm -rf "$T"

# --- Case 20: manifest has -rN suffix but build_dir uses PKG_VERSION only ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/dropbear" "$T/build_dir/target-x/dropbear-2025.89" "$T/bin/targets/x/y"
cat > "$T/package/dropbear/Makefile" <<'MK'
define Package/dropbear
endef
PKG_NAME:=dropbear
PKG_LICENSE:=MIT
MK
printf 'REAL DROPBEAR LICENSE\n' > "$T/build_dir/target-x/dropbear-2025.89/LICENSE"
printf 'dropbear - 2025.89-r1\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) && RC=0 || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 20: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="dropbear") | .text')
assert_contains "REAL DROPBEAR LICENSE" "$TEXT" \
    "case 20: -rN stripped version matched build_dir dropbear-2025.89"
rm -rf "$T"

# --- Case 21: multi-digit release suffix also stripped ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-x/foo-1.0" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=MIT
MK
printf 'REAL FOO\n' > "$T/build_dir/target-x/foo-1.0/LICENSE"
printf 'foo - 1.0-r12\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) && RC=0 || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 21: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="foo") | .text')
assert_contains "REAL FOO" "$TEXT" "case 21: -r12 stripped to match foo-1.0"
rm -rf "$T"

# --- Case 22: VER with no -rN suffix: VER_STRIPPED equals VER, behavior unchanged ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/bar" "$T/build_dir/target-x/bar-2.0" "$T/bin/targets/x/y"
cat > "$T/package/bar/Makefile" <<'MK'
define Package/bar
endef
PKG_NAME:=bar
PKG_LICENSE:=MIT
MK
printf 'REAL BAR\n' > "$T/build_dir/target-x/bar-2.0/LICENSE"
printf 'bar - 2.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) && RC=0 || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 22: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="bar") | .text')
assert_contains "REAL BAR" "$TEXT" "case 22: no -rN, still works"
rm -rf "$T"

# --- Case 23: subpackage ca-bundle finds parent ca-certificates via MK_PKG_NAME + stripped VER ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/ca-certificates" "$T/build_dir/target-x/ca-certificates-20250419" "$T/bin/targets/x/y"
cat > "$T/package/ca-certificates/Makefile" <<'MK'
define Package/ca-certificates
endef
define Package/ca-bundle
endef
PKG_NAME:=ca-certificates
PKG_LICENSE:=GPL-2.0-or-later MPL-2.0
MK
printf 'CA BUNDLE COPYRIGHT TEXT\n' > "$T/build_dir/target-x/ca-certificates-20250419/LICENSE"
printf 'ca-bundle - 20250419-r2\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) && RC=0 || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 23: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ca-bundle") | .text')
assert_contains "CA BUNDLE COPYRIGHT TEXT" "$TEXT" \
    "case 23: ca-bundle resolves via MK_PKG_NAME=ca-certificates + stripped VER"
rm -rf "$T"

# --- Case 24: Debian-style debian/copyright file is discovered ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/build_dir/target-x/foo-1.0/debian" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=GPL-2.0-or-later
MK
printf 'DEBIAN COPYRIGHT TEXT FOR FOO\n' > "$T/build_dir/target-x/foo-1.0/debian/copyright"
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 24: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="foo") | .text')
assert_contains "DEBIAN COPYRIGHT TEXT FOR FOO" "$TEXT" \
    "case 24: debian/copyright at depth 2 is found by find -iname copyright*"
rm -rf "$T"

# --- Case 25: LEGAL.txt-style file is discovered ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/bar" "$T/build_dir/target-x/bar-2.0" "$T/bin/targets/x/y"
cat > "$T/package/bar/Makefile" <<'MK'
define Package/bar
endef
PKG_NAME:=bar
PKG_LICENSE:=Apache-2.0
MK
printf 'LEGAL NOTICE FOR BAR\n' > "$T/build_dir/target-x/bar-2.0/LEGAL.txt"
printf 'bar - 2.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 25: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="bar") | .text')
assert_contains "LEGAL NOTICE FOR BAR" "$TEXT" \
    "case 25: LEGAL.txt at top level is found by find -iname LEGAL*"
rm -rf "$T"

# --- Case 26: ca-bundle scenario (F5-fix-2 + F5-fix-3 combined) ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/ca-certificates" "$T/build_dir/target-x/ca-certificates-20250419/debian" "$T/bin/targets/x/y"
cat > "$T/package/ca-certificates/Makefile" <<'MK'
define Package/ca-certificates
endef
define Package/ca-bundle
endef
PKG_NAME:=ca-certificates
PKG_LICENSE:=GPL-2.0-or-later MPL-2.0
MK
printf 'CA CERT DEBIAN COPYRIGHT\n' > "$T/build_dir/target-x/ca-certificates-20250419/debian/copyright"
printf 'ca-bundle - 20250419-r2\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 26: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="ca-bundle") | .text')
assert_contains "CA CERT DEBIAN COPYRIGHT" "$TEXT" \
    "case 26: ca-bundle full path — MK_PKG_NAME + stripped VER + debian/copyright"
rm -rf "$T"

# --- Case 27: in-tree package with no build_dir, LICENSE alongside Makefile ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/utils/fitblk" "$T/bin/targets/x/y"
cat > "$T/package/utils/fitblk/Makefile" <<'MK'
define Package/fitblk
endef
PKG_NAME:=fitblk
PKG_LICENSE:=GPL-2.0-only
MK
printf 'IN-TREE FITBLK LICENSE\n' > "$T/package/utils/fitblk/LICENSE"
printf 'fitblk - 2\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 27: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="fitblk") | .text')
assert_contains "IN-TREE FITBLK LICENSE" "$TEXT" \
    "case 27: in-tree Makefile-dir LICENSE is found when no build_dir exists"
rm -rf "$T"

# --- Case 28: GPL-2.0-only falls back to LICENSES/GPL-2.0 template ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/LICENSES" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=GPL-2.0-only
MK
printf 'GENERIC GPL-2.0 TEMPLATE BODY\n' > "$T/LICENSES/GPL-2.0"
# No build_dir, no LICENSE in package dir either.
printf 'foo - 1\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 28: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="foo") | .text')
assert_contains "GENERIC GPL-2.0 TEMPLATE BODY" "$TEXT" \
    "case 28: GPL-2.0-only resolves via LICENSES/GPL-2.0 (alias strip)"
rm -rf "$T"

# --- Case 29: GPL-2.0-or-later also resolves via LICENSES/GPL-2.0 ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/bar" "$T/LICENSES" "$T/bin/targets/x/y"
cat > "$T/package/bar/Makefile" <<'MK'
define Package/bar
endef
PKG_NAME:=bar
PKG_LICENSE:=GPL-2.0-or-later
MK
printf 'GPL-2.0 TEMPLATE\n' > "$T/LICENSES/GPL-2.0"
printf 'bar - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 29: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="bar") | .text')
assert_contains "GPL-2.0 TEMPLATE" "$TEXT" \
    "case 29: GPL-2.0-or-later resolves via LICENSES/GPL-2.0 (alias strip)"
rm -rf "$T"

# --- Case 30: if LICENSES/GPL-2.0-only exists, it wins over stripped GPL-2.0 ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/baz" "$T/LICENSES" "$T/bin/targets/x/y"
cat > "$T/package/baz/Makefile" <<'MK'
define Package/baz
endef
PKG_NAME:=baz
PKG_LICENSE:=GPL-2.0-only
MK
printf 'EXACT-MATCH GPL-2.0-only TEMPLATE\n' > "$T/LICENSES/GPL-2.0-only"
printf 'WRONG STRIPPED TEMPLATE\n' > "$T/LICENSES/GPL-2.0"
printf 'baz - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 30: unexpected RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="baz") | .text')
assert_contains "EXACT-MATCH GPL-2.0-only TEMPLATE" "$TEXT" \
    "case 30: exact GPL-2.0-only template wins over stripped fallback"
case "$TEXT" in
    *"WRONG STRIPPED TEMPLATE"*) echo "FAIL: case 30: stripped template leaked"; FAIL=$((FAIL+1));;
esac
rm -rf "$T"

# --- Case 31: kmod-* package resolves via build_dir/target-*/linux-*/<mk_pkg_name>-<stripped_ver>/ ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/kernel/mt76" "$T/build_dir/target-x/linux-y/mt76-20250101~abc" "$T/bin/targets/x/y"
cat > "$T/package/kernel/mt76/Makefile" <<'MK'
define KernelPackage/mt76-connac
endef
PKG_NAME:=mt76
PKG_LICENSE:=BSD-3-Clause-Clear
MK
printf 'MT76 LICENSE BODY\n' > "$T/build_dir/target-x/linux-y/mt76-20250101~abc/LICENSE"
printf 'kmod-mt76-connac - 20250101~abc-r1\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 31: RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="kmod-mt76-connac") | .text')
assert_contains "MT76 LICENSE BODY" "$TEXT" "case 31: kmod via linux-*/mt76-<ver>"
rm -rf "$T"

# --- Case 32: '+' suffix is old-form SPDX alias for '-or-later' ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/mtd" "$T/LICENSES" "$T/bin/targets/x/y"
cat > "$T/package/mtd/Makefile" <<'MK'
define Package/mtd
endef
PKG_NAME:=mtd
PKG_LICENSE:=GPL-2.0+
MK
printf 'GPL-2.0 TEMPLATE\n' > "$T/LICENSES/GPL-2.0"
printf 'mtd - 27\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 32: RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="mtd") | .text')
assert_contains "GPL-2.0 TEMPLATE" "$TEXT" "case 32: GPL-2.0+ strips + to match LICENSES/GPL-2.0"
rm -rf "$T"

# --- Case 33: solarmatrix/licenses/spdx/ fallback for templates not in LICENSES/ ---
CASES=$((CASES + 1))
T=$(mktemp -d)
mkdir -p "$T/package/foo" "$T/solarmatrix/licenses/spdx" "$T/bin/targets/x/y"
cat > "$T/package/foo/Makefile" <<'MK'
define Package/foo
endef
PKG_NAME:=foo
PKG_LICENSE:=LGPL-2.1
MK
printf 'LGPL-2.1 TEMPLATE TEXT\n' > "$T/solarmatrix/licenses/spdx/LGPL-2.1"
printf 'foo - 1.0\n' > "$T/bin/targets/x/y/rootfs.manifest"
RC=0
OUT=$(OPENWRT_TAG=test REPO_ROOT="$T" "$SCRIPT" 2>/dev/null) || RC=$?
[ $RC -eq 0 ] || { echo "FAIL: case 33: RC=$RC"; FAIL=$((FAIL+1)); }
TEXT=$(printf '%s' "$OUT" | jq -r '.notices[] | select(.name=="foo") | .text')
assert_contains "LGPL-2.1 TEMPLATE TEXT" "$TEXT" "case 33: solarmatrix/licenses/spdx/ fallback"
rm -rf "$T"

echo "--- $CASES cases, $FAIL failures ---"
[ "$FAIL" -eq 0 ]

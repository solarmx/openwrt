#!/bin/bash
# Tests for openwrt-one-dts.py: the DTS patch, the source check of the NOR
# partition table, and the same check on a compiled DTB. Needs python3 and dtc.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/testlib.sh"
TOOL="$HERE/openwrt-one-dts.py"
REPO="$(cd "$HERE/.." && pwd)"
DTS_PATH="target/linux/mediatek/dts/mt7981b-openwrt-one.dts"

T=$(mktemp -d)
cp "$REPO/$DTS_PATH" "$T/pristine.dts"

# run MODE FILE [TAG]: sets RC and OUT (stdout and stderr together)
run() {
    RC=0
    OUT="$(python3 "$TOOL" "$@" 2>&1)" || RC=$?
}

# patch_fails NAME INPUT NEEDLE: the patch refuses INPUT, names NEEDLE, and
# leaves the file as it was.
patch_fails() {
    CASES=$((CASES + 1))
    cp "$2" "$T/in.dts"; cp "$2" "$T/in.orig"
    run patch "$T/in.dts" vTEST
    assert_nonzero "$RC" "$1: refused"
    assert_contains "$3" "$OUT" "$1: names the problem"
    assert_eq same "$(cmp -s "$T/in.dts" "$T/in.orig" && echo same)" "$1: file left unmodified"
}

# source_fails NAME INPUT NEEDLE: check-source refuses an already patched INPUT.
source_fails() {
    CASES=$((CASES + 1))
    run check-source "$2"
    assert_nonzero "$RC" "$1: refused"
    assert_contains "$3" "$OUT" "$1: names the problem"
}

# insert_after FILE ANCHOR TEXT [SKIP]: TEXT goes on the line after the first
# line containing ANCHOR (a fixed string), or SKIP lines further down.
insert_after() {
    python3 - "$1" "$2" "$3" "${4:-0}" <<'PY'
import sys
path, anchor, text, skip = sys.argv[1:5]
lines = open(path).read().split("\n")
i = next(n for n, l in enumerate(lines) if anchor in l) + int(skip)
lines.insert(i + 1, text)
open(path, "w").write("\n".join(lines))
PY
}

# --- Case 1: the fork's DTS patches cleanly ---
CASES=$((CASES + 1))
cp "$T/pristine.dts" "$T/patched.dts"
run patch "$T/patched.dts" vTEST
assert_eq 0 "$RC" "case 1: patch succeeds ($OUT)"
assert_eq 1 "$(grep -c -F 'label = "factory-secrets";' "$T/patched.dts")" "case 1: one factory-secrets"
assert_contains 'reg = <0x40000 0xa0000>;' "$(cat "$T/patched.dts")" "case 1: factory shrunk"
assert_contains 'spidev@0' "$(cat "$T/patched.dts")" "case 1: spidev added"

# --- Case 2: the pinned release's DTS patches cleanly ---
CASES=$((CASES + 1))
PINNED="$(sed -n 's/^PINNED_TAG="\(.*\)"$/\1/p' "$HERE/build-firmware.sh")"
if [ -n "$PINNED" ] && git -C "$REPO" show "$PINNED:$DTS_PATH" > "$T/pinned.dts" 2>/dev/null; then
    run patch "$T/pinned.dts" vTEST
    assert_eq 0 "$RC" "case 2: $PINNED patch succeeds ($OUT)"
else
    echo "FAIL: case 2: PINNED_TAG '$PINNED' is not a tag in this clone"; FAIL=$((FAIL + 1))
fi

# --- Case 3: the patched output passes the source check ---
CASES=$((CASES + 1))
run check-source "$T/patched.dts"
assert_eq 0 "$RC" "case 3: patched DTS passes check-source ($OUT)"

# --- Case 4: patching twice is refused and leaves the file alone ---
patch_fails "case 4" "$T/patched.dts" 'factory-secrets appears 2 times'

# --- Case 5: factory without read-only ---
awk '/label = "factory";/{f=1} f && /read-only;/{f=0; next} {print}' "$T/pristine.dts" > "$T/x.dts"
patch_fails "case 5" "$T/x.dts" 'factory is not read-only'

# --- Case 6: a missing nvmem cell ---
awk '/macaddr_factory_24: macaddr@24/{s=1} s{ if (/};/) s=0; next } {print}' "$T/pristine.dts" > "$T/x.dts"
patch_fails "case 6" "$T/x.dts" 'nvmem cell macaddr@24 is missing'

# --- Case 7: overlapping partitions ---
sed 's/reg = <0x100000 0x80000>;/reg = <0xf0000 0x90000>;/' "$T/pristine.dts" > "$T/x.dts"
patch_fails "case 7" "$T/x.dts" 'factory-secrets (0xe0000-0xfffff) overlaps fip-nor'

# --- Case 8: a gap between partitions ---
sed 's/reg = <0x180000 0xc80000>;/reg = <0x190000 0xc70000>;/' "$T/pristine.dts" > "$T/x.dts"
patch_fails "case 8" "$T/x.dts" 'gap between fip-nor'

# --- Case 9: upstream changed the factory size ---
sed 's/reg = <0x40000 0xc0000>;/reg = <0x40000 0xb0000>;/' "$T/pristine.dts" > "$T/x.dts"
patch_fails "case 9" "$T/x.dts" 'factory partition was not shrunk'

# --- Case 10: factory-secrets marked read-only ---
cp "$T/patched.dts" "$T/x.dts"
insert_after "$T/x.dts" 'reg = <0xe0000 0x20000>;' '				read-only;'
source_fails "case 10" "$T/x.dts" 'factory-secrets is read-only'

# --- Case 11: a child not named partition@ still counts (b1) ---
cp "$T/patched.dts" "$T/x.dts"
insert_after "$T/x.dts" 'reg = <0x00000 0x40000>;' '			};
			macs@40000 { label = "macs"; reg = <0x40000 0x1000>;'
source_fails "case 11" "$T/x.dts" 'macs@40000 (macs) 0x40000+0x1000 is not in the NOR layout'

# --- Case 12: a child with no reg ---
cp "$T/patched.dts" "$T/x.dts"
insert_after "$T/x.dts" 'reg = <0x180000 0xc80000>;' '			};
			stray { label = "stray";'
source_fails "case 12" "$T/x.dts" 'NOR child stray has no parsable reg'

# --- Case 13: /delete-property/ inside the NOR table (b2) ---
cp "$T/patched.dts" "$T/x.dts"
insert_after "$T/x.dts" 'reg = <0x40000 0xa0000>;' '				/delete-property/ read-only;' 1
source_fails "case 13" "$T/x.dts" '/delete-property/ read-only'

# --- Case 14: a path override elsewhere in the file (b3) ---
cp "$T/patched.dts" "$T/x.dts"
printf '\n&{/soc/spi@1100b000/flash@0/partitions/partition@40000} {\n\t/delete-property/ read-only;\n};\n' >> "$T/x.dts"
source_fails "case 14" "$T/x.dts" 'path reference &{/soc/spi@1100b000/flash@0/partitions/partition@40000}'

# --- Case 15: a label override of a factory nvmem cell ---
cp "$T/patched.dts" "$T/x.dts"
printf '\n&macaddr_factory_4 {\n\treg = <0x2000 0x6>;\n};\n' >> "$T/x.dts"
source_fails "case 15" "$T/x.dts" '&macaddr_factory_4 overrides a node of the NOR table'

# --- DTB checks: the patched flash node, compiled on its own by dtc ---
# wrap_flash IN OUT [EXTRA]: a minimal tree holding IN's &spi2 flash@0 node at
# the path the real SoC has (the controller labelled spi2), followed by EXTRA.
# DTC_FLAGS=-@ adds __symbols__, as an overlay-capable build does.
wrap_flash() {
    {
        printf '/dts-v1/;\n/ {\n\tsoc {\n\t\t#address-cells = <1>;\n\t\t#size-cells = <1>;\n'
        printf '\t\tspi2: spi@1100b000 {\n\t\t\treg = <0x1100b000 0x100>;\n\t\t\t#address-cells = <1>;\n\t\t\t#size-cells = <0>;\n'
        awk '/^&spi2 \{/{s=1} s && /^\tflash@0 \{/{f=1} f{print} f && /^\t\};/{exit}' "$1"
        printf '\t\t};\n\t};\n};\n%s\n' "${3:-}"
    } > "$T/wrap.dts"
    local flags=()
    [ -z "${DTC_FLAGS:-}" ] || flags=("$DTC_FLAGS")
    dtc -q ${flags[@]+"${flags[@]}"} -I dts -O dtb -o "$2" "$T/wrap.dts"
}

dtb_fails() {
    CASES=$((CASES + 1))
    run check-dtb "$2"
    assert_nonzero "$RC" "$1: refused"
    assert_contains "$3" "$OUT" "$1: names the problem"
}

# --- Case 16: the compiled patched table passes ---
CASES=$((CASES + 1))
wrap_flash "$T/patched.dts" "$T/good.dtb"
run check-dtb "$T/good.dtb"
assert_eq 0 "$RC" "case 16: compiled table passes ($OUT)"

# --- Case 17: a path override that deletes read-only is caught in the DTB ---
wrap_flash "$T/patched.dts" "$T/b3.dtb" \
    '&{/soc/spi@1100b000/flash@0/partitions/partition@40000} { /delete-property/ read-only; };'
dtb_fails "case 17" "$T/b3.dtb" 'factory is not read-only'

# --- Case 18: the node reopened to delete read-only is caught in the DTB ---
# (dtc ignores a /delete-property/ in the same body as the property, as in
# case 13; that form is refused by the source check and harmless when built.)
wrap_flash "$T/patched.dts" "$T/b2.dtb" \
    '/ { soc { spi@1100b000 { flash@0 { partitions { partition@40000 { /delete-property/ read-only; }; }; }; }; }; };'
dtb_fails "case 18" "$T/b2.dtb" 'factory is not read-only'

# --- Case 19: an extra child over the MACs is caught in the DTB ---
cp "$T/patched.dts" "$T/x.dts"
insert_after "$T/x.dts" 'reg = <0x00000 0x40000>;' '			};
			macs@40000 { label = "macs"; reg = <0x40000 0x1000>;'
wrap_flash "$T/x.dts" "$T/b1.dtb"
dtb_fails "case 19" "$T/b1.dtb" 'macs@40000 (macs) 0x40000+0x1000 is not in the NOR layout'

# --- Case 20: a DTB without a NOR flash ---
printf '/dts-v1/;\n/ { model = "none"; };\n' > "$T/empty.dts"
dtc -q -I dts -O dtb -o "$T/empty.dtb" "$T/empty.dts"
dtb_fails "case 20" "$T/empty.dtb" 'no spi2 controller: no __symbols__/spi2 and no spi@1100b000 node'

# --- Case 21: a missing DTB ---
dtb_fails "case 21" "$T/missing.dtb" 'cannot decompile'

# --- Case 22: a partitions node that is not fixed-partitions (m_compat) ---
sed 's/compatible = "fixed-partitions";/compatible = "acme,unknown-partitions";/' "$T/patched.dts" > "$T/x.dts"
source_fails "case 22" "$T/x.dts" 'partitions node is "acme,unknown-partitions", expected "fixed-partitions"'
CASES=$((CASES + 1))
wrap_flash "$T/x.dts" "$T/compat.dtb"
run check-dtb "$T/compat.dtb"
assert_nonzero "$RC" "case 22: DTB refused"
assert_contains 'expected "fixed-partitions"' "$OUT" "case 22: DTB names the problem"

# --- Case 23: factory's nvmem-layout that is not fixed-layout ---
sed 's/compatible = "fixed-layout";/compatible = "acme,layout";/' "$T/patched.dts" > "$T/x.dts"
source_fails "case 23" "$T/x.dts" 'factory nvmem-layout is "acme,layout", expected "fixed-layout"'

# --- Case 24: a decoy jedec,spi-nor carries the table, the real flash is renamed (m_second) ---
awk '/^&spi2 \{/{s=1} s && /^\tflash@0 \{/{f=1} f{print} f && /^\t\};/{exit}' "$T/patched.dts" |
    sed 's/[A-Za-z_0-9]*: //; s/reg = <0>;/status = "disabled";/' > "$T/decoy.txt"
sed '/^&spi2 {/,/^};/s/compatible = "jedec,spi-nor";/compatible = "winbond,w25q512jv";/' "$T/patched.dts" > "$T/x.dts"
wrap_flash "$T/x.dts" "$T/decoy.dtb" "/ { decoy { $(cat "$T/decoy.txt") }; };"
dtb_fails "case 24" "$T/decoy.dtb" '/decoy/flash@0/partitions also carries NOR partitions'

# --- Case 25: the NOR flash disabled ---
wrap_flash "$T/patched.dts" "$T/disabled.dtb" '&{/soc/spi@1100b000/flash@0} { status = "disabled"; };'
dtb_fails "case 25" "$T/disabled.dtb" '/soc/spi@1100b000/flash@0 is disabled'

# --- Case 26: the controller found through __symbols__ ---
CASES=$((CASES + 1))
DTC_FLAGS=-@ wrap_flash "$T/patched.dts" "$T/symbols.dtb"
run check-dtb "$T/symbols.dtb"
assert_eq 0 "$RC" "case 26: __symbols__/spi2 is followed ($OUT)"

# --- Case 27: __symbols__/spi2 wins over the unit address ---
sed 's/^\t\tspi2: spi@1100b000 {/\t\tspi@1100b000 {/' "$T/wrap.dts" > "$T/x.dts" # keep the tree, move the label
printf '/ { soc { spi2: spi@1100a000 { reg = <0x1100a000 0x100>; #address-cells = <1>; #size-cells = <0>; }; }; };\n' >> "$T/x.dts"
dtc -q -@ -I dts -O dtb -o "$T/moved.dtb" "$T/x.dts"
dtb_fails "case 27" "$T/moved.dtb" '/soc/spi@1100a000 has no flash@0'

# --- Case 28: the controller itself disabled ---
wrap_flash "$T/patched.dts" "$T/spi-off.dtb" '&{/soc/spi@1100b000} { status = "disabled"; };'
dtb_fails "case 28" "$T/spi-off.dtb" '/soc/spi@1100b000 is disabled'

rm -rf "$T"
finish

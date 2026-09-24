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
printf '\n&{/soc/spi@11009000/flash@0/partitions/partition@40000} {\n\t/delete-property/ read-only;\n};\n' >> "$T/x.dts"
source_fails "case 14" "$T/x.dts" 'path reference &{/soc/spi@11009000/flash@0/partitions/partition@40000}'

# --- Case 15: a label override of a factory nvmem cell ---
cp "$T/patched.dts" "$T/x.dts"
printf '\n&macaddr_factory_4 {\n\treg = <0x2000 0x6>;\n};\n' >> "$T/x.dts"
source_fails "case 15" "$T/x.dts" '&macaddr_factory_4 overrides a node of the NOR table'

# --- DTB checks: the patched flash nodes, compiled on their own by dtc ---
# flash_block IN CTRL: IN's flash@0 node under &CTRL, as text.
flash_block() {
    awk -v ctrl="$2" '$0 == "&" ctrl " {" {s=1} s && /^\tflash@0 \{/{f=1} f{print} f && /^\t\};/{exit}' "$1"
}
# wrap_tree NORFILE OUT [EXTRA]: a minimal tree laid out like the real SoC
# (mt7981b.dtsi via patches-6.12/117-complete-mt7981b-dtsi.patch): NORFILE's
# flash nodes on spi2 = spi@11009000, the fork's NAND flash on spi0 =
# spi@1100a000, the mikroBUS spidev on spi1 = spi@1100b000, then EXTRA.
# DTC_FLAGS=-@ adds __symbols__, as an overlay-capable build does.
wrap_tree() {
    {
        printf '/dts-v1/;\n/ {\n\t#address-cells = <2>;\n\t#size-cells = <2>;\n'
        printf '\tsoc {\n\t\t#address-cells = <2>;\n\t\t#size-cells = <2>;\n'
        printf '\t\tspi2: spi@11009000 {\n\t\t\treg = <0 0x11009000 0 0x1000>;\n\t\t\t#address-cells = <1>;\n\t\t\t#size-cells = <0>;\n'
        cat "$1"
        printf '\t\t};\n'
        printf '\t\tspi0: spi@1100a000 {\n\t\t\treg = <0 0x1100a000 0 0x1000>;\n\t\t\t#address-cells = <1>;\n\t\t\t#size-cells = <0>;\n'
        flash_block "$T/pristine.dts" spi0 | sed 's/^\([[:space:]]*\)[A-Za-z_][A-Za-z_0-9]*: /\1/'
        printf '\t\t};\n'
        printf '\t\tspi1: spi@1100b000 {\n\t\t\treg = <0 0x1100b000 0 0x1000>;\n\t\t\t#address-cells = <1>;\n\t\t\t#size-cells = <0>;\n'
        printf '\t\t\tspidev@0 { compatible = "silabs,si3210"; reg = <0>; };\n\t\t};\n'
        printf '\t};\n};\n%s\n' "${3:-}"
    } > "$T/wrap.dts"
    local flags=()
    [ -z "${DTC_FLAGS:-}" ] || flags=("$DTC_FLAGS")
    dtc -q ${flags[@]+"${flags[@]}"} -I dts -O dtb -o "$2" "$T/wrap.dts"
}
# wrap_flash IN OUT [EXTRA]: wrap_tree with IN's NOR flash.
wrap_flash() {
    flash_block "$1" spi2 > "$T/nor.txt"
    wrap_tree "$T/nor.txt" "$2" "${3:-}"
}

dtb_fails() {
    CASES=$((CASES + 1))
    run check-dtb "$2"
    assert_nonzero "$RC" "$1: refused"
    assert_contains "$3" "$OUT" "$1: names the problem"
}

# --- Case 16: the compiled patched table passes; no __symbols__, the NAND
# table on spi0 is allowed, and spi@1100b000 carrying spidev is not the NOR ---
CASES=$((CASES + 1))
wrap_flash "$T/patched.dts" "$T/good.dtb"
run check-dtb "$T/good.dtb"
assert_eq 0 "$RC" "case 16: compiled table passes ($OUT)"
assert_not_contains "__symbols__" "$(dtc -q -I dtb -O dts "$T/good.dtb")" "case 16: fixture has no __symbols__"

# --- Case 17: a path override that deletes read-only is caught in the DTB ---
wrap_flash "$T/patched.dts" "$T/b3.dtb" \
    '&{/soc/spi@11009000/flash@0/partitions/partition@40000} { /delete-property/ read-only; };'
dtb_fails "case 17" "$T/b3.dtb" 'factory is not read-only'

# --- Case 18: the node reopened to delete read-only is caught in the DTB ---
# (dtc ignores a /delete-property/ in the same body as the property, as in
# case 13; that form is refused by the source check and harmless when built.)
wrap_flash "$T/patched.dts" "$T/b2.dtb" \
    '/ { soc { spi@11009000 { flash@0 { partitions { partition@40000 { /delete-property/ read-only; }; }; }; }; }; };'
dtb_fails "case 18" "$T/b2.dtb" 'factory is not read-only'

# --- Case 19: an extra child over the MACs is caught in the DTB ---
cp "$T/patched.dts" "$T/x.dts"
insert_after "$T/x.dts" 'reg = <0x00000 0x40000>;' '			};
			macs@40000 { label = "macs"; reg = <0x40000 0x1000>;'
wrap_flash "$T/x.dts" "$T/b1.dtb"
dtb_fails "case 19" "$T/b1.dtb" 'macs@40000 (macs) 0x40000+0x1000 is not in the NOR layout'

# --- Case 20: a DTB without the spi2 controller ---
printf '/dts-v1/;\n/ { model = "none"; };\n' > "$T/empty.dts"
dtc -q -I dts -O dtb -o "$T/empty.dtb" "$T/empty.dts"
dtb_fails "case 20" "$T/empty.dtb" 'expected one spi@11009000 node (spi2), found 0'

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
flash_block "$T/patched.dts" spi2 | sed 's/[A-Za-z_0-9]*: //; s/reg = <0>;/status = "disabled";/' > "$T/decoy.txt"
sed '/^&spi2 {/,/^};/s/compatible = "jedec,spi-nor";/compatible = "winbond,w25q512jv";/' "$T/patched.dts" > "$T/x.dts"
wrap_flash "$T/x.dts" "$T/decoy.dtb" "/ { decoy { $(cat "$T/decoy.txt") }; };"
dtb_fails "case 24" "$T/decoy.dtb" '/decoy/flash@0/partitions is a partition table outside the NOR and NAND flashes'

# --- Case 25: the NOR flash disabled ---
wrap_flash "$T/patched.dts" "$T/disabled.dtb" '&{/soc/spi@11009000/flash@0} { status = "disabled"; };'
dtb_fails "case 25" "$T/disabled.dtb" '/soc/spi@11009000 has no enabled CS0 flash (reg = <0>)'

# --- Case 26: an honest __symbols__ passes ---
CASES=$((CASES + 1))
DTC_FLAGS=-@ wrap_flash "$T/patched.dts" "$T/symbols.dtb"
assert_contains 'spi2 = "/soc/spi@11009000"' "$(dtc -q -I dtb -O dts "$T/symbols.dtb")" "case 26: fixture has __symbols__"
run check-dtb "$T/symbols.dtb"
assert_eq 0 "$RC" "case 26: __symbols__/spi2 = /soc/spi@11009000 passes ($OUT)"

# --- Case 27: __symbols__/spi2 pointing at a path not in the tree ---
wrap_flash "$T/patched.dts" "$T/sym-missing.dtb" '/ { __symbols__ { spi2 = "/soc/spi@nowhere"; }; };'
dtb_fails "case 27" "$T/sym-missing.dtb" '__symbols__/spi2 is "/soc/spi@nowhere", expected "/soc/spi@11009000"'

# --- Case 28: the controller itself disabled ---
wrap_flash "$T/patched.dts" "$T/spi-off.dtb" '&{/soc/spi@11009000} { status = "disabled"; };'
dtb_fails "case 28" "$T/spi-off.dtb" '/soc/spi@11009000 is disabled'

# --- Case 29: two spi@11009000 nodes under different parents ---
wrap_flash "$T/patched.dts" "$T/two.dtb" \
    '/ { bus { #address-cells = <2>; #size-cells = <2>; spi@11009000 { reg = <0 0x11009000 0 0x1000>; }; }; };'
dtb_fails "case 29" "$T/two.dtb" 'expected one spi@11009000 node (spi2), found 2'

# --- Case 30: __symbols__/spi2 redirected to a decoy (x_sym2) ---
flash_block "$T/patched.dts" spi2 | sed 's/[A-Za-z_0-9]*: //' > "$T/decoy.txt"
wrap_flash "$T/patched.dts" "$T/sym-decoy.dtb" \
    "/ { decoy { #address-cells = <1>; #size-cells = <0>; $(cat "$T/decoy.txt") }; __symbols__ { spi2 = \"/decoy\"; }; };"
dtb_fails "case 30" "$T/sym-decoy.dtb" '__symbols__/spi2 is "/decoy", expected "/soc/spi@11009000"'

# --- Case 31: a decoy CS1 node named flash@0, the real CS0 flash named flash@1
# with renamed labels and a writable factory (x_cs) ---
cat > "$T/cs.txt" <<'EOF'
	flash@0 { compatible = "acme,nothing"; reg = <1>; };
	flash@1 {
		compatible = "jedec,spi-nor";
		reg = <0>;
		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;
			partition@0 { label = "bl2"; reg = <0x0 0x40000>; };
			partition@40000 { label = "factory-rw"; reg = <0x40000 0xa0000>; };
			partition@e0000 { label = "secrets"; reg = <0xe0000 0x20000>; };
			partition@100000 { label = "fip"; reg = <0x100000 0x80000>; };
			partition@180000 { label = "rec"; reg = <0x180000 0xc80000>; };
		};
	};
EOF
wrap_tree "$T/cs.txt" "$T/cs.dtb"
dtb_fails "case 31" "$T/cs.dtb" 'partition@40000 (factory-rw) 0x40000+0xa0000 is not in the NOR layout'

# --- Case 32: a second child of spi2 with its own partitions ---
flash_block "$T/patched.dts" spi2 > "$T/nor2.txt"
printf '\tflash@1 { compatible = "jedec,spi-nor"; reg = <1>; partitions { compatible = "fixed-partitions"; #address-cells = <1>; #size-cells = <1>; part@0 { label = "x"; reg = <0x0 0x1000>; }; }; };\n' >> "$T/nor2.txt"
wrap_tree "$T/nor2.txt" "$T/cs1.dtb"
dtb_fails "case 32" "$T/cs1.dtb" '/soc/spi@11009000/flash@1 has a partitions node but is not the enabled CS0 flash'

# --- Case 33: an extra fixed-partitions table elsewhere, arbitrary labels ---
wrap_flash "$T/patched.dts" "$T/extra.dtb" \
    '/ { mmc { card { partitions { compatible = "fixed-partitions"; #address-cells = <1>; #size-cells = <1>; part@0 { label = "anything"; reg = <0x0 0x1000>; }; }; }; }; };'
dtb_fails "case 33" "$T/extra.dtb" '/mmc/card/partitions is a partition table outside the NOR and NAND flashes'

# --- Case 34: spi@11009000 whose reg is somewhere else ---
flash_block "$T/patched.dts" spi2 > "$T/nor.txt"
wrap_tree "$T/nor.txt" "$T/reg.dtb"
sed 's/reg = <0 0x11009000 0 0x1000>;/reg = <0 0x11008000 0 0x1000>;/' "$T/wrap.dts" > "$T/x.dts"
dtc -q -I dts -O dtb -o "$T/reg.dtb" "$T/x.dts"
dtb_fails "case 34" "$T/reg.dtb" '/soc/spi@11009000 reg starts at 0x11008000, expected 0x11009000'

# --- Case 35: the only spi@11009000 is not at /soc ---
sed 's/^\tsoc {$/\tbus {/' "$T/wrap.dts" > "$T/x.dts"
dtc -q -I dts -O dtb -o "$T/moved.dtb" "$T/x.dts"
dtb_fails "case 35" "$T/moved.dtb" 'spi2 is at /bus/spi@11009000, expected /soc/spi@11009000'

rm -rf "$T"
finish

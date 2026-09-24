#!/bin/bash
# Tests for build-gates.sh: the .config, overlay, rootfs, image and staging
# gates of build-firmware.sh, run against fake build trees. No build needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/testlib.sh"
. "$HERE/build-gates.sh"
FILES="$HERE/files"
V=25.12.5

T=$(mktemp -d)

# run CMD...: runs a gate in a subshell; sets RC and OUT (stdout + stderr)
run() {
    RC=0
    OUT="$( ( "$@" ) 2>&1)" || RC=$?
}
expect_ok() {
    CASES=$((CASES + 1))
    run "${@:2}"
    assert_eq 0 "$RC" "$1: passes ($OUT)"
}
expect_fail() {
    CASES=$((CASES + 1))
    local name="$1" needle="$2"; shift 2
    run "$@"
    assert_nonzero "$RC" "$name: refused"
    assert_contains "$needle" "$OUT" "$name: names the problem"
}

# A build tree whose rootfs holds the overlay and passes every gate.
mkbuild() {
    B="$T/b"; rm -rf "$B"
    R="$B/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
    IMG="$B/bin/targets/mediatek/filogic"
    mkdir -p "$R/lib/preinit" "$R/usr/sbin" "$IMG" \
        "$B/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic"
    cp -a "$FILES/." "$R/"
    echo 'pi_preinit_no_failsafe="y"' > "$R/lib/preinit/00_preinit.conf"
    head -c 1000 /dev/zero > "$IMG/openwrt-$V-mediatek-filogic-openwrt_one-initramfs.itb"
    : > "$B/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/image-mt7981b-openwrt-one.dtb"
}

# A .config that passes check_defconfig.
mkconfig() {
    C="$T/config"
    for p in "${REQUIRED_PACKAGES[@]}"; do echo "CONFIG_PACKAGE_$p=y"; done > "$C"
    {
        echo "CONFIG_VERSION_NUMBER=\"$V\""
        echo 'CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE=y'
        echo '# CONFIG_PACKAGE_odhcpd-ipv6only is not set'
        echo '# CONFIG_TARGET_PER_DEVICE_ROOTFS is not set'
        echo '# CONFIG_PACKAGE_kmod-mtd-rw is not set'
    } >> "$C"
}

# --- defconfig ---
mkconfig; expect_ok "case 1: a good .config" check_defconfig "$C" "$V"
mkconfig; grep -v -F 'CONFIG_PACKAGE_cryptsetup=y' "$C" > "$C.x"; mv "$C.x" "$C"
expect_fail "case 2: a dropped package" 'dropped these packages: cryptsetup' check_defconfig "$C" "$V"
mkconfig; grep -v -F 'DISABLE_FAILSAFE' "$C" > "$C.x"; mv "$C.x" "$C"
expect_fail "case 3: failsafe dropped" 'CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE' check_defconfig "$C" "$V"
mkconfig; echo 'CONFIG_PACKAGE_odhcpd-ipv6only=y' >> "$C"
expect_fail "case 4: odhcpd selected" 'odhcpd is still selected' check_defconfig "$C" "$V"
mkconfig; echo 'CONFIG_TARGET_PER_DEVICE_ROOTFS=y' >> "$C"
expect_fail "case 5: per-device rootfs" 'CONFIG_TARGET_PER_DEVICE_ROOTFS is set' check_defconfig "$C" "$V"
mkconfig; echo 'CONFIG_PACKAGE_kmod-mtd-rw=m' >> "$C"
expect_fail "case 6: kmod-mtd-rw as a module" 'kmod-mtd-rw is selected' check_defconfig "$C" "$V"
mkconfig; echo 'CONFIG_PACKAGE_kmod-mtd-rw=y' >> "$C"
expect_fail "case 7: kmod-mtd-rw built in" 'kmod-mtd-rw is selected' check_defconfig "$C" "$V"
mkconfig; grep -v -F 'CONFIG_VERSION_NUMBER' "$C" > "$C.x"; mv "$C.x" "$C"
expect_fail "case 8: version dropped" 'dropped CONFIG_VERSION_NUMBER' check_defconfig "$C" "$V"

# --- overlay listing ---
expect_ok "case 9: every overlay file is listed" check_overlay_listed "$FILES"
cp -a "$FILES" "$T/files"; ln -s /etc/shadow "$T/files/etc/stray-link"
expect_fail "case 10: an unlisted symlink" 'etc/stray-link' check_overlay_listed "$T/files"
rm -rf "$T/files"; cp -a "$FILES" "$T/files"; touch "$T/files/etc/stray"
expect_fail "case 11: an unlisted file" 'etc/stray' check_overlay_listed "$T/files"
rm -rf "$T/files"

# --- rootfs dir ---
mkbuild; expect_ok "case 12: one rootfs dir" find_rootfs_dir "$B/build_dir"
CASES=$((CASES + 1)); assert_eq "$R" "$(find_rootfs_dir "$B/build_dir")" "case 12: prints it"
mkbuild; mkdir -p "$B/build_dir/target-other/root-mediatek"
expect_fail "case 13: two rootfs dirs" 'expected one rootfs staging directory' find_rootfs_dir "$B/build_dir"
mkbuild; rm -rf "$R"
expect_fail "case 14: no rootfs dir" 'expected one rootfs staging directory' find_rootfs_dir "$B/build_dir"

# --- stale deletion reaches every overlay path, the depth-6 one included ---
CASES=$((CASES + 1))
mkbuild; delete_stale_overlay "$B/build_dir"
assert_eq "lib/preinit/00_preinit.conf" "$(cd "$R" && find . ! -type d | sed 's|^\./||')" "case 15: only non-overlay files left"

# --- overlay in rootfs ---
mkbuild; expect_ok "case 16: the overlay reached the rootfs" check_overlay_in_rootfs "$FILES" "$R"
mkbuild; echo x >> "$R/etc/uci-defaults/50-root-passwd"
expect_fail "case 17: package 50-root-passwd not replaced" '50-root-passwd does not match' check_overlay_in_rootfs "$FILES" "$R"
mkbuild; echo x >> "$R/etc/uci-defaults/50-dropbear"
expect_fail "case 18: package 50-dropbear not replaced" '50-dropbear does not match' check_overlay_in_rootfs "$FILES" "$R"
mkbuild; chmod -x "$R/usr/sbin/solarmatrix-storage"
expect_fail "case 19: storage not executable" 'solarmatrix-storage is not executable' check_overlay_in_rootfs "$FILES" "$R"

# --- rootfs gates ---
mkbuild; expect_ok "case 20: a clean rootfs" check_rootfs_gates "$R"
mkbuild; echo 'pi_preinit_no_failsafe=""' > "$R/lib/preinit/00_preinit.conf"
expect_fail "case 21: failsafe on" 'failsafe is not disabled' check_rootfs_gates "$R"
mkbuild; echo '::askconsole:/usr/libexec/login.sh' >> "$R/etc/inittab"
expect_fail "case 22: serial login" 'still starts a serial login' check_rootfs_gates "$R"
mkbuild; touch "$R/usr/sbin/odhcpd"
expect_fail "case 23: odhcpd" 'odhcpd is in the rootfs' check_rootfs_gates "$R"
mkbuild; ln -s /nonexistent "$R/usr/sbin/odhcpd"
expect_fail "case 24: a dangling odhcpd symlink" 'odhcpd is in the rootfs' check_rootfs_gates "$R"
mkbuild; mkdir -p "$R/sbin"; touch "$R/sbin/solarmatrix-harden-ssh"
expect_fail "case 25: harden-ssh" 'obsolete solarmatrix-harden-ssh' check_rootfs_gates "$R"
mkbuild; sed "s/option enable '0'/option enable '1'/" "$FILES/etc/config/dropbear" > "$R/etc/config/dropbear"
expect_fail "case 26: dropbear shipped enabled" "does not ship with enable '0'" check_rootfs_gates "$R"

# --- initramfs: this version's exact file only ---
mkbuild; expect_ok "case 27: initramfs fits" check_initramfs "$B/bin/targets" "$V"
mkbuild; head -c 13107200 /dev/zero > "$IMG/openwrt-$V-mediatek-filogic-openwrt_one-initramfs.itb"
expect_ok "case 28: exactly the recovery size" check_initramfs "$B/bin/targets" "$V"
mkbuild; head -c 13107201 /dev/zero > "$IMG/openwrt-$V-mediatek-filogic-openwrt_one-initramfs.itb"
expect_fail "case 29: one byte too big" 'larger than the NOR recovery partition' check_initramfs "$B/bin/targets" "$V"
mkbuild; mv "$IMG/openwrt-$V-mediatek-filogic-openwrt_one-initramfs.itb" "$IMG/openwrt-25.12.4-mediatek-filogic-openwrt_one-initramfs.itb"
expect_fail "case 30: only a stale older initramfs" "openwrt-$V-mediatek-filogic-openwrt_one-initramfs.itb is missing" check_initramfs "$B/bin/targets" "$V"

# --- DTB ---
mkbuild; expect_ok "case 31: one DTB" find_dtb "$B/build_dir"
mkbuild; mkdir -p "$B/build_dir/target-other/linux-mediatek_filogic"; : > "$B/build_dir/target-other/linux-mediatek_filogic/image-mt7981b-openwrt-one.dtb"
expect_fail "case 32: two DTBs" 'expected one image-mt7981b-openwrt-one.dtb' find_dtb "$B/build_dir"
mkbuild; rm "$B"/build_dir/target-*/linux-mediatek_filogic/image-mt7981b-openwrt-one.dtb
expect_fail "case 33: no DTB" 'expected one image-mt7981b-openwrt-one.dtb' find_dtb "$B/build_dir"

# --- staging: only this version's images, into a fresh out/ ---
CASES=$((CASES + 1))
mkbuild
for f in squashfs-sysupgrade.itb factory.ubi nor-preloader.bin nor-bl31-uboot.fip; do : > "$IMG/openwrt-$V-mediatek-filogic-openwrt_one-$f"; done
: > "$IMG/openwrt-$V-mediatek-filogic-openwrt_one.manifest"
: > "$IMG/profiles.json"; : > "$IMG/sha256sums"; : > "$IMG/config.buildinfo"
: > "$IMG/openwrt-25.12.4-mediatek-filogic-openwrt_one-initramfs.itb"
: > "$IMG/openwrt-imagebuilder-$V-mediatek-filogic.Linux-x86_64.tar.zst"
O="$T/out"; mkdir -p "$O"; : > "$O/openwrt-25.12.3-mediatek-filogic-openwrt_one-factory.ubi"
reset_out_dir "$O"; : > "$O/openwrt-licenses.json"
run stage_artifacts "$B/bin/targets" "$O" "$V"
assert_eq 0 "$RC" "case 34: staging succeeds ($OUT)"
assert_eq "openwrt-$V-mediatek-filogic-openwrt_one-factory.ubi
openwrt-$V-mediatek-filogic-openwrt_one-initramfs.itb
openwrt-$V-mediatek-filogic-openwrt_one-nor-bl31-uboot.fip
openwrt-$V-mediatek-filogic-openwrt_one-nor-preloader.bin
openwrt-$V-mediatek-filogic-openwrt_one-squashfs-sysupgrade.itb
openwrt-$V-mediatek-filogic-openwrt_one.manifest
openwrt-licenses.json
profiles.json
sha256sums" "$(ls "$O")" "case 34: only this build's images, no older ones"

mkbuild; rm "$IMG"/*
expect_fail "case 35: nothing to stage" "no openwrt-$V-mediatek-filogic-* images" stage_artifacts "$B/bin/targets" "$T/out" "$V"

rm -rf "$T"
finish

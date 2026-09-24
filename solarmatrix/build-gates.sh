# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck shell=bash
#
# The checks build-firmware.sh runs on its .config, its rootfs overlay, the
# staged rootfs and the built images. Sourced, not run; every function prints
# an ERROR line and returns non-zero on failure, so under `set -e` a failed
# gate stops the build. Kept apart from the build so build-gates_test.sh can
# run each gate against a fake tree.

# Packages that make this device work. defconfig drops unknown symbols without
# comment, and a missing kmod-nvme or kmod-spi-dev has shipped before without
# an error at build time.
REQUIRED_PACKAGES=(
    kmod-spi-dev kmod-nvme kmod-fs-ext4 parted e2fsprogs blkid curl
    ca-certificates cryptsetup kmod-dm kmod-crypto-xts
)

# Every file solarmatrix/files puts in the rootfs, split by how the rootfs copy
# is checked: executables must also keep their x bit; the rest are sourced or
# read. The data files include ones a package also ships (inittab,
# config/dropbear, the two uci-defaults): matching ours proves the overlay
# replaced the package's version.
OVERLAY_EXECUTABLES=(
    etc/uci-defaults/99-solarmatrix-hardening
    etc/hotplug.d/block/20-solarmatrix-nvme
    etc/init.d/solarmatrix-mount
    etc/init.d/solarmatrix
    usr/sbin/solarmatrix-storage
)
OVERLAY_DATA=(
    lib/solarmatrix/secrets.sh
    lib/solarmatrix/storage.sh
    etc/solarmatrix/provisioning.pub
    etc/security-model
    etc/inittab
    etc/config/dropbear
    etc/uci-defaults/50-dropbear
    etc/uci-defaults/50-root-passwd
)

# NOR "recovery" partition, 0xc80000: the initramfs is flashed there.
RECOVERY_MAX=13107200

gate_error() {
    local line
    for line in "$@"; do echo "$line" >&2; done
    return 1
}

# check_defconfig CONFIG VERSION_NUMBER
check_defconfig() {
    local config="$1" version="$2" pkg missing=""
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        grep -q -x -F "CONFIG_PACKAGE_$pkg=y" "$config" || missing="$missing $pkg"
    done
    [ -z "$missing" ] || gate_error "ERROR: defconfig dropped these packages:$missing" \
        "  They are not selectable in this tree -- are the feeds installed?" || return 1
    grep -q -x -F "CONFIG_VERSION_NUMBER=\"$version\"" "$config" ||
        gate_error "ERROR: defconfig dropped CONFIG_VERSION_NUMBER=\"$version\"" \
            "  Images would be built as SNAPSHOT rather than as this release." || return 1
    grep -q -x -F 'CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE=y' "$config" ||
        gate_error "ERROR: defconfig dropped CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE" \
            "  The image would offer a passwordless failsafe shell." || return 1
    if grep -q '^CONFIG_PACKAGE_odhcpd' "$config"; then
        gate_error "ERROR: odhcpd is still selected:" "$(grep '^CONFIG_PACKAGE_odhcpd' "$config")"
        return 1
    fi
    # Per-device rootfs would let the device profile's package list, not this
    # .config, decide what the openwrt_one image contains.
    if grep -q '^CONFIG_TARGET_PER_DEVICE_ROOTFS=y$' "$config"; then
        gate_error "ERROR: CONFIG_TARGET_PER_DEVICE_ROOTFS is set; the image contents would not be this .config"
        return 1
    fi
    # kmod-mtd-rw forces every MTD partition writable, factory included.
    if grep -q -E '^CONFIG_PACKAGE_kmod-mtd-rw=(y|m)$' "$config"; then
        gate_error "ERROR: kmod-mtd-rw is selected; it would make the read-only factory partition writable"
        return 1
    fi
    echo "Verified: all ${#REQUIRED_PACKAGES[@]} requested packages are selected, release $version,"
    echo "  failsafe disabled, no odhcpd, no per-device rootfs, no kmod-mtd-rw"
}

# check_overlay_listed FILES_DIR: every entry but a directory must be in a list,
# so a new file -- or a symlink -- cannot ship unchecked.
check_overlay_listed() {
    local unlisted
    unlisted="$(cd "$1" && find . ! -type d | sed 's|^\./||' | sort |
        grep -v -x -F -f <(printf '%s\n' "${OVERLAY_EXECUTABLES[@]}" "${OVERLAY_DATA[@]}") || true)"
    [ -z "$unlisted" ] && return 0
    gate_error "ERROR: $1 has entries the post-build check does not cover:"
    printf '%s\n' "$unlisted" | sed 's/^/  /' >&2
    return 1
}

# delete_stale_overlay BUILD_DIR: build_dir is not cleaned between builds, so a
# previous build's copy of an overlay file would satisfy the post-build check
# even if this build never applied the overlay. Paths are removed relative to
# each rootfs staging dir, so no search depth has to match the deepest one.
delete_stale_overlay() {
    local root file
    while IFS= read -r root; do
        for file in "${OVERLAY_EXECUTABLES[@]}" "${OVERLAY_DATA[@]}"; do
            rm -f "$root/$file"
        done
    done < <(find "$1" -mindepth 2 -maxdepth 2 -type d -name 'root-*')
}

# find_rootfs_dir BUILD_DIR: prints the one rootfs staging directory. More than
# one means an older target's rootfs could be the one checked.
find_rootfs_dir() {
    local dirs count
    dirs="$(find "$1" -mindepth 2 -maxdepth 2 -type d -path "$1/target-*/root-mediatek*")"
    count="$(printf '%s' "$dirs" | grep -c '' || true)"
    [ "$count" = 1 ] || { gate_error "ERROR: expected one rootfs staging directory $1/target-*/root-mediatek*, found $count" \
        ${dirs:+"$dirs"}; return 1; }
    printf '%s\n' "$dirs"
}

# find_dtb BUILD_DIR: prints the one compiled OpenWRT One DTB.
find_dtb() {
    local dtbs count
    dtbs="$(find "$1" -mindepth 3 -maxdepth 3 -type f -path "$1/target-*/linux-mediatek_filogic/image-mt7981b-openwrt-one.dtb")"
    count="$(printf '%s' "$dtbs" | grep -c '' || true)"
    [ "$count" = 1 ] || { gate_error "ERROR: expected one image-mt7981b-openwrt-one.dtb under $1/target-*/linux-mediatek_filogic, found $count" \
        ${dtbs:+"$dtbs"}; return 1; }
    printf '%s\n' "$dtbs"
}

# check_overlay_in_rootfs FILES_DIR ROOTFS: byte for byte, not merely found, so
# a stale, truncated or package-supplied copy fails.
check_overlay_in_rootfs() {
    local src="$1" root="$2" file
    for file in "${OVERLAY_EXECUTABLES[@]}" "${OVERLAY_DATA[@]}"; do
        cmp -s "$src/$file" "$root/$file" ||
            gate_error "ERROR: $file does not match solarmatrix/files/ in the rootfs" \
                "  Expected: $src/$file" "  In rootfs: $root/$file" || return 1
    done
    for file in "${OVERLAY_EXECUTABLES[@]}"; do
        [ -x "$root/$file" ] ||
            gate_error "ERROR: $file is not executable in the rootfs" || return 1
    done
    echo "Verified: all $(( ${#OVERLAY_EXECUTABLES[@]} + ${#OVERLAY_DATA[@]} )) overlay files in $root"
}

# check_rootfs_gates ROOTFS: what the rootfs must not contain, checked in the
# staged rootfs rather than in .config, so a package that sneaks back in
# through a dependency, or an overlay that did not take, still fails:
#   - failsafe, a passwordless root shell on a key press during preinit;
#   - a serial login (base-files' inittab starts login.sh on the console);
#   - odhcpd, a root-run LAN DHCPv6/RA server this IPv4-only LAN never needs;
#   - solarmatrix-harden-ssh, removed with the boot access policy rewrite;
#   - a dropbear config that listens before 99-solarmatrix-hardening decides.
check_rootfs_gates() {
    local root="$1"
    grep -q -x -F 'pi_preinit_no_failsafe="y"' "$root/lib/preinit/00_preinit.conf" ||
        gate_error "ERROR: failsafe is not disabled in $root/lib/preinit/00_preinit.conf" || return 1
    if grep -q -F 'login.sh' "$root/etc/inittab"; then
        gate_error "ERROR: $root/etc/inittab still starts a serial login"; return 1
    fi
    if [ -e "$root/usr/sbin/odhcpd" ] || [ -L "$root/usr/sbin/odhcpd" ]; then
        gate_error "ERROR: odhcpd is in the rootfs"; return 1
    fi
    if [ -e "$root/sbin/solarmatrix-harden-ssh" ] || [ -L "$root/sbin/solarmatrix-harden-ssh" ]; then
        gate_error "ERROR: the obsolete solarmatrix-harden-ssh is in the rootfs"; return 1
    fi
    grep -q "^[[:space:]]*option enable '0'\$" "$root/etc/config/dropbear" ||
        gate_error "ERROR: $root/etc/config/dropbear does not ship with enable '0'" || return 1
    echo "Verified: failsafe off, no serial login, no odhcpd, dropbear shipped disabled"
}

# check_initramfs BIN_TARGETS VERSION_NUMBER: this build's initramfs by its
# exact name, so an older release's image left in bin/ is never measured.
check_initramfs() {
    local img="$1/mediatek/filogic/openwrt-$2-mediatek-filogic-openwrt_one-initramfs.itb" size
    [ -f "$img" ] || gate_error "ERROR: $img is missing" || return 1
    size="$(wc -c < "$img" | tr -d ' ')"
    [ "$size" -le "$RECOVERY_MAX" ] ||
        gate_error "ERROR: $img is $size bytes, larger than the NOR recovery partition ($RECOVERY_MAX bytes)" || return 1
    echo "Verified: initramfs fits recovery ($size of $RECOVERY_MAX bytes)"
}

# reset_out_dir OUT: out/ holds only what this build stages.
reset_out_dir() {
    rm -rf "$1"
    mkdir -p "$1"
}

# stage_artifacts BIN_TARGETS OUT VERSION_NUMBER: copies this build's images
# (named for its version) and profiles.json into OUT, and writes OUT's own
# sha256sums over the staged images. OpenWrt's sha256sums is not copied: it
# covers the whole target dir, packages and older images included, so
# `sha256sum -c` would fail in OUT.
stage_artifacts() {
    local dir="$1/mediatek/filogic" out="$2" version="$3" images img
    images="$(find "$dir" -maxdepth 1 -type f -name "openwrt-$version-mediatek-filogic-*" \
        \( -name '*.itb' -o -name '*.ubi' -o -name '*.bin' -o -name '*.fip' \
        -o -name '*.img*' -o -name '*.manifest' \) 2>/dev/null | sort)"
    [ -n "$images" ] || gate_error "ERROR: no openwrt-$version-mediatek-filogic-* images in $dir" || return 1
    [ -f "$dir/profiles.json" ] || gate_error "ERROR: $dir/profiles.json is missing" || return 1
    while IFS= read -r img; do
        cp "$img" "$out/" || gate_error "ERROR: could not copy $img to $out" || return 1
        echo "$img"
    done <<< "$images"
    cp "$dir/profiles.json" "$out/" || gate_error "ERROR: could not copy $dir/profiles.json to $out" || return 1
    ( cd "$out" && sha256sum -b -- "openwrt-$version"-* ) > "$out/sha256sums" ||
        gate_error "ERROR: could not write $out/sha256sums" || return 1
}

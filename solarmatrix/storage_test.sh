#!/bin/bash
# Tests for files/lib/solarmatrix/storage.sh and its callers (the
# solarmatrix-mount init script, the block hotplug script and the
# solarmatrix-storage CLI). No device needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/testlib.sh"
LIBDIR="$HERE/files/lib/solarmatrix"
INIT="$HERE/files/etc/init.d/solarmatrix-mount"
HOTPLUG="$HERE/files/etc/hotplug.d/block/20-solarmatrix-nvme"
CLI="$HERE/files/usr/sbin/solarmatrix-storage"
KEY="$(printf 'ef%.0s' $(seq 32))"
JSON='{"v":1,"serial":"SM-1","ssh_keys":["k"],"nvme_key":"'"$KEY"'"}'

make_sandbox() {
    local t="$1"
    mkdir -p "$t/bin" "$t/mapper" "$t/mnt"
    : > "$t/mounts"; : > "$t/mount.log"; : > "$t/crypt.log"; : > "$t/logger.log"; : > "$t/argv.log"; : > "$t/lock.log"
    make_empty_secrets "$t/secrets"
    printf '#!/bin/sh\necho "${BLKID_TYPE:-}"\n' > "$t/bin/blkid"
    cat > "$t/bin/cryptsetup" <<'CS'
#!/bin/sh
printf 'argv: %s\n' "$*" >> "$CRYPT_LOG"
[ "$1" = open ] && printf 'stdin: %s\n' "$(cat)" >> "$CRYPT_LOG"
[ "${CRYPT_FAIL:-0}" = 1 ] && exit 1
case "$1" in
open) touch "$MAPPER_DIR/$(eval echo \${$#})" ;;
close) [ "${CRYPT_CLOSE_FAIL:-0}" = 1 ] && exit 1; rm -f "$MAPPER_DIR/$2" ;;
esac
exit 0
CS
    cat > "$t/bin/mount" <<'MNT'
#!/bin/sh
printf '%s\n' "$*" >> "$MOUNT_LOG"
[ "${MOUNT_FAIL:-0}" = 1 ] && exit 1
printf '%s %s ext4 rw 0 0\n' "$3" "$4" >> "$SOLARMATRIX_MOUNTS"
exit 0
MNT
    cat > "$t/bin/umount" <<'UMNT'
#!/bin/sh
printf '%s\n' "$*" >> "$MOUNT_LOG"
grep -vF " $1 " "$SOLARMATRIX_MOUNTS" > "$SOLARMATRIX_MOUNTS.new"
mv "$SOLARMATRIX_MOUNTS.new" "$SOLARMATRIX_MOUNTS"
exit 0
UMNT
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LOGGER_LOG"\n' > "$t/bin/logger"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LOCK_LOG"\n' > "$t/bin/lock"
    # The real jsonfilter reads stdin when given neither -s nor -i. This wrapper
    # records its argv (the key must never show up there) and hands stdin to
    # the shared fake.
    install_fake_jsonfilter "$t/bin"
    mv "$t/bin/jsonfilter" "$t/bin/jsonfilter.py"
    cat > "$t/bin/jsonfilter" <<'JF'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV_LOG"
case " $* " in *" -s "*|*" -i "*) exec "$(dirname "$0")/jsonfilter.py" "$@" ;; esac
exec "$(dirname "$0")/jsonfilter.py" -s "$(cat)" "$@"
JF
    chmod 755 "$t"/bin/*
}

# in_sandbox DIR CMD...: runs CMD with the fakes first on PATH and the
# library pointed at the sandbox.
in_sandbox() {
    local t="$1"; shift
    env PATH="$t/bin:$PATH" SOLARMATRIX_LIB="$LIBDIR" SOLARMATRIX_SECRETS_DEV="$t/secrets" \
        SOLARMATRIX_MOUNTS="$t/mounts" SOLARMATRIX_MAPPER_DIR="$t/mapper" MAPPER_DIR="$t/mapper" \
        MOUNT_LOG="$t/mount.log" CRYPT_LOG="$t/crypt.log" LOGGER_LOG="$t/logger.log" ARGV_LOG="$t/argv.log" \
        LOCK_LOG="$t/lock.log" SOLARMATRIX_LOCK="$t/storage.lock" SOLARMATRIX_MOUNT_POINT="$t/mnt" "$@"
}

run_mount() {
    local t="$1"; shift
    in_sandbox "$t" "$@" sh -c ". '$LIBDIR/storage.sh'; sm_storage_mount /dev/nvme0n1p1 '$t/mnt'"
}

# A refusal of a LUKS partition with valid secrets: nothing opened or mounted.
refused_before_cryptsetup() {
    local n="$1" json="$2" t rc
    CASES=$((CASES + 1)); t=$(mktemp -d); make_sandbox "$t"; make_secrets "$t/secrets" "$json"
    rc=0; run_mount "$t" env BLKID_TYPE=crypto_LUKS >/dev/null 2>&1 || rc=$?
    assert_nonzero "$rc" "case $n: refused"
    assert_eq '' "$(cat "$t/crypt.log")" "case $n: cryptsetup never called"
    assert_eq '' "$(cat "$t/mount.log")" "case $n: nothing mounted"
    assert_contains 'daemon.crit' "$(cat "$t/logger.log")" "case $n: logged at crit"
    rm -rf "$t"
}

# --- Case 1: provisioned + LUKS opens with the key on stdin and mounts ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
RC=0; OUT=$(run_mount "$T" env BLKID_TYPE=crypto_LUKS 2>&1) || RC=$?
assert_eq 0 "$RC" "case 1: mounted"
assert_contains "stdin: $KEY" "$(cat "$T/crypt.log")" "case 1: key passed on stdin"
assert_contains "argv: open --type luks2 --key-file=- /dev/nvme0n1p1 solarmatrix" \
    "$(cat "$T/crypt.log")" "case 1: cryptsetup open arguments"
assert_not_contains "$KEY" "$(grep '^argv' "$T/crypt.log")" "case 1: key never in cryptsetup argv"
assert_not_contains "$KEY" "$(cat "$T/argv.log")" "case 1: key never in jsonfilter argv"
assert_eq "-t ext4 $T/mapper/solarmatrix $T/mnt" "$(cat "$T/mount.log")" "case 1: mounts the mapper device ext4, no options"
assert_not_contains "$KEY" "$(cat "$T/logger.log")" "case 1: key never logged"
assert_not_contains "$KEY" "$OUT" "case 1: key never on stdout/stderr"
rm -rf "$T"

# --- Case 2: provisioned + plain ext4 is refused (fail closed) ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
RC=0; run_mount "$T" env BLKID_TYPE=ext4 >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 2: refused"
assert_eq '' "$(cat "$T/mount.log")" "case 2: nothing mounted"
assert_eq '' "$(cat "$T/crypt.log")" "case 2: no cryptsetup"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 2: logged at crit"
rm -rf "$T"

# --- Case 3: unprovisioned (or pilot) + ext4 mounts plain ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; run_mount "$T" env BLKID_TYPE=ext4 >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 3: legacy plain mount works"
assert_eq "-t ext4 /dev/nvme0n1p1 $T/mnt" "$(cat "$T/mount.log")" "case 3: plain partition mounted, no options"
assert_eq '' "$(cat "$T/crypt.log")" "case 3: no cryptsetup"
rm -rf "$T"

# --- Case 4: unprovisioned + LUKS is refused (no key to open it) ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; run_mount "$T" env BLKID_TYPE=crypto_LUKS >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 4: refused"
assert_eq '' "$(cat "$T/mount.log")" "case 4: nothing mounted"
assert_eq '' "$(cat "$T/crypt.log")" "case 4: no cryptsetup"
assert_contains 'daemon.warn' "$(cat "$T/logger.log")" "case 4: logged at warn"
rm -rf "$T"

# --- Case 5: corrupt secrets refuse everything ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
printf 'X' | dd of="$T/secrets" bs=1 seek=100 conv=notrunc 2>/dev/null
RC=0; run_mount "$T" env BLKID_TYPE=ext4 >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 5: refused"
assert_eq '' "$(cat "$T/mount.log")" "case 5: nothing mounted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 5: logged at crit"
rm -rf "$T"

# --- Cases 6-9: unusable nvme_key is refused before cryptsetup runs ---
refused_before_cryptsetup 6 '{"v":1,"ssh_keys":["k"],"nvme_key":"not-hex"}'
refused_before_cryptsetup 7 '{"v":1,"ssh_keys":["k"]}'
refused_before_cryptsetup 8 '{"v":1,"nvme_key":"'"$KEY"'"'
refused_before_cryptsetup 9 '{"v":1,"nvme_key":"'"$(printf 'EF%.0s' $(seq 32))"'"}'
refused_before_cryptsetup 10 '{"v":1,"nvme_key":"'"${KEY}0"'"}'

# --- Case 11: a wrong key (cryptsetup fails) mounts nothing ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
RC=0; run_mount "$T" env BLKID_TYPE=crypto_LUKS CRYPT_FAIL=1 >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 11: refused"
assert_eq '' "$(cat "$T/mount.log")" "case 11: nothing mounted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 11: logged at crit"
rm -rf "$T"

# --- Case 12: already mounted is a no-op success ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
printf '/dev/mapper/solarmatrix %s ext4 rw 0 0\n' "$T/mnt" > "$T/mounts"
RC=0; run_mount "$T" env BLKID_TYPE=ext4 >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 12: success"
assert_eq '' "$(cat "$T/mount.log")" "case 12: not mounted twice"
rm -rf "$T"

# --- Case 13: init start without the NVMe partition exits 0 quietly ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; OUT=$(in_sandbox "$T" env BLKID_TYPE=ext4 sh -c ". '$INIT'; start" 2>&1) || RC=$?
assert_eq 0 "$RC" "case 13: exits 0"
assert_eq '' "$OUT" "case 13: prints nothing"
assert_eq '' "$(cat "$T/mount.log")" "case 13: nothing mounted"
assert_eq '' "$(cat "$T/logger.log")" "case 13: nothing logged"
rm -rf "$T"

# --- Case 14: hotplug ignores any device other than nvme0n1p1 ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; touch "$T/mapper/solarmatrix"
for dev in sda1 nvme0n1 nvme0n1p2 nvme1n1p1; do
    for action in add remove; do
        RC=0
        in_sandbox "$T" env BLKID_TYPE=ext4 DEVICENAME="$dev" ACTION="$action" \
            sh "$HOTPLUG" >/dev/null 2>&1 || RC=$?
        assert_eq 0 "$RC" "case 14: $dev $action exits 0"
    done
done
assert_eq '' "$(cat "$T/mount.log")" "case 14: nothing mounted or unmounted"
assert_eq '' "$(cat "$T/crypt.log")" "case 14: no cryptsetup"
rm -rf "$T"

# --- Case 15: hotplug remove of nvme0n1p1 unmounts and closes the volume ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; touch "$T/mapper/solarmatrix"
printf '/dev/mapper/solarmatrix %s ext4 rw 0 0\n' "$T/mnt" > "$T/mounts"
RC=0; in_sandbox "$T" env DEVICENAME=nvme0n1p1 ACTION=remove sh "$HOTPLUG" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 15: exits 0"
assert_eq "$T/mnt" "$(cat "$T/mount.log")" "case 15: unmounted the mount point"
assert_eq 'argv: close solarmatrix' "$(cat "$T/crypt.log")" "case 15: closed the mapper"
rm -rf "$T"

# --- Case 16: init stop unmounts and closes the volume ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; touch "$T/mapper/solarmatrix"
printf '/dev/mapper/solarmatrix %s ext4 rw 0 0\n' "$T/mnt" > "$T/mounts"
RC=0; in_sandbox "$T" sh -c ". '$INIT'; stop" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 16: exits 0"
assert_eq "$T/mnt" "$(cat "$T/mount.log")" "case 16: unmounted the mount point"
assert_eq 'argv: close solarmatrix' "$(cat "$T/crypt.log")" "case 16: closed the mapper"
rm -rf "$T"

# --- Case 17: a stale mapper is closed and reopened with this unit's key ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
touch "$T/mapper/solarmatrix"
RC=0; run_mount "$T" env BLKID_TYPE=crypto_LUKS >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 17: mounted"
assert_eq "argv: close solarmatrix
argv: open --type luks2 --key-file=- /dev/nvme0n1p1 solarmatrix
stdin: $KEY" "$(cat "$T/crypt.log")" "case 17: closed, then opened fresh with the key"
assert_eq "-t ext4 $T/mapper/solarmatrix $T/mnt" "$(cat "$T/mount.log")" "case 17: mounts the fresh mapper"
rm -rf "$T"

# --- Case 18: a stale mapper that will not close is refused ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
touch "$T/mapper/solarmatrix"
RC=0; run_mount "$T" env BLKID_TYPE=crypto_LUKS CRYPT_CLOSE_FAIL=1 >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 18: refused"
assert_eq 'argv: close solarmatrix' "$(cat "$T/crypt.log")" "case 18: never opened"
assert_eq '' "$(cat "$T/mount.log")" "case 18: nothing mounted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 18: logged at crit"
rm -rf "$T"

# --- Case 19: a mount failure after opening closes the volume again ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
RC=0; run_mount "$T" env BLKID_TYPE=crypto_LUKS MOUNT_FAIL=1 >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 19: refused"
assert_eq 'argv: close solarmatrix' "$(tail -n 1 "$T/crypt.log")" "case 19: mapper closed after the failed mount"
assert_eq 'no' "$([ -e "$T/mapper/solarmatrix" ] && echo yes || echo no)" "case 19: no mapper left behind"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 19: logged at crit"
rm -rf "$T"

# --- Case 20: hotplug add of nvme0n1p1 mounts it ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; in_sandbox "$T" env BLKID_TYPE=ext4 DEVICENAME=nvme0n1p1 ACTION=add sh "$HOTPLUG" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 20: exits 0"
assert_eq "-t ext4 /dev/nvme0n1p1 $T/mnt" "$(cat "$T/mount.log")" "case 20: mounted"
rm -rf "$T"

# --- Case 21: mount and umount hold the storage lock, and release it on refusal ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
LOCKED="$T/storage.lock
-u $T/storage.lock"
run_mount "$T" env BLKID_TYPE=ext4 >/dev/null 2>&1
assert_eq "$LOCKED" "$(cat "$T/lock.log")" "case 21: mount locks and unlocks"
: > "$T/lock.log"; : > "$T/mounts"
run_mount "$T" env BLKID_TYPE=crypto_LUKS >/dev/null 2>&1
assert_eq "$LOCKED" "$(cat "$T/lock.log")" "case 21: a refused mount unlocks"
: > "$T/lock.log"
in_sandbox "$T" sh -c ". '$LIBDIR/storage.sh'; sm_storage_umount '$T/mnt'" >/dev/null 2>&1
assert_eq "$LOCKED" "$(cat "$T/lock.log")" "case 21: umount locks and unlocks"
rm -rf "$T"

# --- Case 22: CLI umount unmounts and closes the volume ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; touch "$T/mapper/solarmatrix"
printf '/dev/mapper/solarmatrix %s ext4 rw 0 0\n' "$T/mnt" > "$T/mounts"
RC=0; in_sandbox "$T" sh "$CLI" umount >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 22: exits 0"
assert_eq "$T/mnt" "$(cat "$T/mount.log")" "case 22: unmounted"
assert_eq 'argv: close solarmatrix' "$(cat "$T/crypt.log")" "case 22: closed the mapper"
rm -rf "$T"

# --- Case 23: CLI mount refuses a plain ext4 on a provisioned unit ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
RC=0; in_sandbox "$T" env BLKID_TYPE=ext4 sh "$CLI" mount >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 23: refused"
assert_eq '' "$(cat "$T/mount.log")" "case 23: nothing mounted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 23: logged at crit"
rm -rf "$T"

# --- Case 24: CLI remount goes through storage.sh both ways ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$JSON"
touch "$T/mapper/solarmatrix"
printf '/dev/mapper/solarmatrix %s ext4 rw 0 0\n' "$T/mnt" > "$T/mounts"
RC=0; in_sandbox "$T" env BLKID_TYPE=crypto_LUKS sh "$CLI" remount >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 24: exits 0"
assert_eq "$T/mnt
-t ext4 $T/mapper/solarmatrix $T/mnt" "$(cat "$T/mount.log")" "case 24: unmounted, then mounted the mapper"
assert_eq "argv: close solarmatrix
argv: open --type luks2 --key-file=- /dev/nvme0n1p1 solarmatrix
stdin: $KEY" "$(cat "$T/crypt.log")" "case 24: closed, then reopened with the key"
rm -rf "$T"

# --- Case 25: CLI help points at the syslog tag ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
assert_contains 'logread -e solarmatrix-storage' "$(in_sandbox "$T" sh "$CLI" help 2>&1)" "case 25: help names the log"
rm -rf "$T"

finish

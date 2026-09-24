#!/bin/bash
# Tests for files/etc/uci-defaults/99-solarmatrix-hardening. Each case builds a
# sandbox with fake uci/service/logger/jsonfilter on PATH, a fake
# factory-secrets image and a fake /proc/mounts, runs the script, and asserts
# on the result.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/testlib.sh"
SCRIPT="$HERE/files/etc/uci-defaults/99-solarmatrix-hardening"
LIBDIR="$HERE/files/lib/solarmatrix"
DROPBEAR_CONFIG="$HERE/files/etc/config/dropbear"
REAL_SED="$(command -v sed)"

NVME_KEY="$(printf 'cd%.0s' $(seq 32))"
KEYS_JSON='{"v":1,"serial":"SM-1","ssh_keys":["ssh-ed25519 AAAA unit-a","ssh-ed25519 BBBB unit-b"],"wifi":{"ssid":"SolarMatrix-1","key":"s3cret-wifi"},"nvme_key":"'"$NVME_KEY"'"}'

# /proc/mounts as the two boot media show it. The NOR recovery system is an
# initramfs; NAND mounts an overlay over the squashfs.
MOUNTS_NOR='rootfs / rootfs rw 0 0
proc /proc proc rw,nosuid,nodev,noexec,noatime 0 0'
MOUNTS_NOR_TMPFS='tmpfs / tmpfs rw,nosuid,noatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,noatime 0 0'
MOUNTS_NAND='/dev/root /rom squashfs ro,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,noatime 0 0
overlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper 0 0'

make_sandbox() {
    local t="$1"
    mkdir -p "$t/bin" "$t/etc/dropbear"
    : > "$t/uci.state"; : > "$t/service.log"; : > "$t/logger.log"; : > "$t/argv.log"
    printf 'root:$1$old$hash:19000:0:99999:7:::\ndaemon:*:0:0:99999:7:::\n' > "$t/shadow"
    printf 'ssh-ed25519 PPPP provisioning\n' > "$t/provisioning.pub"
    printf 'ssh-ed25519 STALE left-over\n' > "$t/etc/dropbear/authorized_keys"
    make_empty_secrets "$t/secrets"

    # Every call's argv goes to ARGV_LOG, so a test can prove no secret was
    # ever visible in ps.
    cat > "$t/bin/uci" <<'UCI'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$ARGV_LOG"
while [ "$1" = "-q" ]; do shift; done
cmd="$1"; shift
uci_set() {
    [ "$1" = "${UCI_FAIL_KEY:-}" ] && return 0
    awk -F= -v k="$1" '$1!=k' "$UCI_STATE" > "$UCI_STATE.new"; mv "$UCI_STATE.new" "$UCI_STATE"
    printf '%s=%s\n' "$1" "$2" >> "$UCI_STATE"
}
case "$cmd" in
set)   uci_set "${1%%=*}" "${1#*=}" ;;
batch) while IFS= read -r line; do
           case "$line" in
           set\ *) kv="${line#set }"; key="${kv%%=*}"; val="${kv#*=}"
                   val="${val#\'}"; val="${val%\'}"
                   val="$(printf '%s' "$val" | sed "s/'\\\\''/'/g")"
                   uci_set "$key" "$val" ;;
           *) exit 2 ;;
           esac
       done ;;
get)  awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; f=1 } END { exit !f }' "$UCI_STATE" || exit 1 ;;
show) grep -q "^$1\." "$UCI_STATE" || exit 1; grep "^$1\." "$UCI_STATE" ;;
commit) ;;
*) exit 2 ;;
esac
UCI
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SERVICE_LOG"\n' > "$t/bin/service"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LOGGER_LOG"\n' > "$t/bin/logger"
    install_fake_jsonfilter "$t/bin"
    mv "$t/bin/jsonfilter" "$t/bin/jsonfilter.real"
    # Real jsonfilter reads stdin when given neither -s nor -i.
    cat > "$t/bin/jsonfilter" <<'JF'
#!/bin/sh
printf 'jsonfilter %s\n' "$*" >> "$ARGV_LOG"
real="$(dirname "$0")/jsonfilter.real"
case " $* " in *" -s "*|*" -i "*) exec "$real" "$@" ;; esac
exec "$real" -s "$(cat)" "$@"
JF
    # Records the mode of any temp file beside the shadow file at the moment
    # the script rewrites it, before any content lands in it.
    cat > "$t/bin/sed" <<SED
#!/bin/sh
for a; do last="\$a"; done
if [ "\${last:-}" = "\$SOLARMATRIX_SHADOW" ]; then
    for f in "\$last".*; do [ -e "\$f" ] && ls -l "\$f" | cut -c1-10 >> "\$SHADOW_MODE_LOG"; done
fi
exec "$REAL_SED" "\$@"
SED
    chmod 755 "$t"/bin/*
}

# run_boot DIR MOUNTS [COMMAND-PREFIX...]
run_boot() {
    local t="$1" mounts="$2"; shift 2
    printf '%s\n' "$mounts" > "$t/mounts"
    ( umask 022
    env PATH="$t/bin:$PATH" UCI_STATE="$t/uci.state" SERVICE_LOG="$t/service.log" \
        LOGGER_LOG="$t/logger.log" ARGV_LOG="$t/argv.log" SOLARMATRIX_LIB="$LIBDIR" \
        SHADOW_MODE_LOG="$t/shadow-mode.log" \
        SOLARMATRIX_SECRETS_DEV="$t/secrets" SOLARMATRIX_MOUNTS="$t/mounts" \
        SOLARMATRIX_SHADOW="$t/shadow" SOLARMATRIX_AUTH_KEYS="$t/etc/dropbear/authorized_keys" \
        SOLARMATRIX_PROVISIONING_KEY="$t/provisioning.pub" "$@" sh "$SCRIPT" )
}

wifi_sections() { printf 'wireless.default_radio0=wifi-iface\nwireless.default_radio1=wifi-iface\n' >> "$1/uci.state"; }

# --- Case 1: NAND never starts dropbear, even when provisioned ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$KEYS_JSON"
RC=0; run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 1: exits 0"
assert_contains 'dropbear.@dropbear[0].enable=0' "$(cat "$T/uci.state")" "case 1: dropbear disabled on NAND"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 1: no keys on NAND"
rm -rf "$T"

# --- Case 2: NOR, unprovisioned: only the provisioning key ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || RC=$?
STATE="$(cat "$T/uci.state")"
assert_eq 0 "$RC" "case 2: exits 0"
assert_contains 'dropbear.@dropbear[0].enable=1' "$STATE" "case 2: dropbear on NOR"
assert_contains 'dropbear.@dropbear[0].PasswordAuth=off' "$STATE" "case 2: password auth off"
assert_contains 'dropbear.@dropbear[0].RootPasswordAuth=off' "$STATE" "case 2: root password auth off"
assert_contains 'dropbear.@dropbear[0].DirectInterface=lan' "$STATE" "case 2: bound to lan"
assert_eq 'ssh-ed25519 PPPP provisioning' "$(cat "$T/etc/dropbear/authorized_keys")" "case 2: provisioning key only"
rm -rf "$T"

# --- Case 3: NOR, provisioned: the unit's own keys, not the provisioning key ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$KEYS_JSON"
RC=0; run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || RC=$?
KEYS="$(cat "$T/etc/dropbear/authorized_keys")"
assert_eq 0 "$RC" "case 3: exits 0"
assert_eq "$(printf 'ssh-ed25519 AAAA unit-a\nssh-ed25519 BBBB unit-b')" "$KEYS" "case 3: exactly the unit's keys"
assert_not_contains 'PPPP' "$KEYS" "case 3: provisioning key refused once provisioned"
rm -rf "$T"

# --- Case 4: NOR, corrupt secrets: no key at all, logged, APs down ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$KEYS_JSON"; wifi_sections "$T"
printf 'X' | dd of="$T/secrets" bs=1 seek=100 conv=notrunc 2>/dev/null
RC=0; run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 4: exits non-zero"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 4: no key accepted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 4: logged at daemon.crit"
assert_contains 'wireless.default_radio0.disabled=1' "$(cat "$T/uci.state")" "case 4: APs down"
assert_contains 'wireless.default_radio1.disabled=1' "$(cat "$T/uci.state")" "case 4: both APs down"
rm -rf "$T"

# --- Case 5: NOR, provisioned with zero keys: no fallback to the provisioning key ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
make_secrets "$T/secrets" '{"v":1,"serial":"SM-1","ssh_keys":[]}'
RC=0; run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 5: exits non-zero"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 5: nothing accepted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 5: logged at daemon.crit"
assert_contains 'no SSH keys' "$(cat "$T/logger.log")" "case 5: log says why"
rm -rf "$T"

# --- Case 6: root password field becomes *, other accounts untouched ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || true
assert_eq 'root:*:19000:0:99999:7:::' "$(sed -n 1p "$T/shadow")" "case 6: root field is *"
assert_eq 'daemon:*:0:0:99999:7:::' "$(sed -n 2p "$T/shadow")" "case 6: other lines unchanged"
assert_eq 2 "$(wc -l < "$T/shadow" | tr -d ' ')" "case 6: no lines added or lost"
rm -rf "$T"

# --- Case 7: ttylogin forced on; NAND unprovisioned has no SSH either ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 7: exits 0"
assert_contains 'system.@system[0].ttylogin=1' "$(cat "$T/uci.state")" "case 7: ttylogin=1"
assert_contains 'dropbear.@dropbear[0].enable=0' "$(cat "$T/uci.state")" "case 7: dropbear disabled on NAND"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 7: no keys on NAND"
rm -rf "$T"

# --- Case 8: provisioned WiFi from the secrets; the key never reaches the log ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$KEYS_JSON"; wifi_sections "$T"
OUT=$(run_boot "$T" "$MOUNTS_NAND" 2>&1) || true
STATE="$(cat "$T/uci.state")"
for r in 0 1; do
    assert_contains "wireless.default_radio$r.ssid=SolarMatrix-1" "$STATE" "case 8: radio$r SSID"
    assert_contains "wireless.default_radio$r.key=s3cret-wifi" "$STATE" "case 8: radio$r key"
    assert_contains "wireless.default_radio$r.encryption=psk2" "$STATE" "case 8: radio$r WPA2"
    assert_contains "wireless.default_radio$r.disabled=0" "$STATE" "case 8: radio$r AP up"
done
assert_not_contains 's3cret-wifi' "$(cat "$T/logger.log") $OUT" "case 8: WiFi key never logged"
rm -rf "$T"

# --- Case 9: unprovisioned: WiFi APs down ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; wifi_sections "$T"
run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || true
assert_contains 'wireless.default_radio0.disabled=1' "$(cat "$T/uci.state")" "case 9: APs down"
assert_contains 'wireless.default_radio1.disabled=1' "$(cat "$T/uci.state")" "case 9: both APs down"
rm -rf "$T"

# --- Case 10: a setting that does not take is logged and does not skip the rest ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; run_boot "$T" "$MOUNTS_NAND" env UCI_FAIL_KEY='system.@system[0].ttylogin' >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 10: exits non-zero so it runs again next boot"
assert_contains 'ttylogin' "$(cat "$T/logger.log")" "case 10: log names the setting"
assert_contains 'dropbear.@dropbear[0].enable=0' "$(cat "$T/uci.state")" "case 10: later concerns still ran"
rm -rf "$T"

# --- Case 11: uhttpd disabled when present ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
printf 'uhttpd.main.listen_http=0.0.0.0:80\n' >> "$T/uci.state"
run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || true
assert_contains 'uhttpd disable' "$(cat "$T/service.log")" "case 11: uhttpd disabled"
rm -rf "$T"

# --- Case 12: hash-valid image whose JSON does not parse: no key, no fallback, APs down ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; wifi_sections "$T"
make_secrets "$T/secrets" '{"v":1,"ssh_keys":["ssh-ed25519 AAAA unit-a"],"wifi":{"ssid":"SolarMatrix-1","key":"s3cret-wifi"'
RC=0; OUT=$(run_boot "$T" "$MOUNTS_NOR" 2>&1) || RC=$?
STATE="$(cat "$T/uci.state")"
assert_nonzero "$RC" "case 12: exits non-zero"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 12: no key accepted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 12: logged at daemon.crit"
assert_contains 'wireless.default_radio0.disabled=1' "$STATE" "case 12: APs down"
assert_not_contains 'wireless.default_radio0.ssid' "$STATE" "case 12: no SSID applied"
assert_not_contains 's3cret-wifi' "$(cat "$T/logger.log") $OUT" "case 12: WiFi key never logged"
rm -rf "$T"

# --- Case 13: no secret is ever passed on a command line ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; make_secrets "$T/secrets" "$KEYS_JSON"; wifi_sections "$T"
run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || true
ARGV="$(cat "$T/argv.log")"
assert_contains 'wireless.default_radio0.key=s3cret-wifi' "$(cat "$T/uci.state")" "case 13: key applied"
assert_not_contains 's3cret-wifi' "$ARGV" "case 13: WiFi key never in argv"
assert_not_contains "$NVME_KEY" "$ARGV" "case 13: NVMe key never in argv"
rm -rf "$T"

# --- Case 14: a value with a single quote survives uci batch quoting ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; wifi_sections "$T"
make_secrets "$T/secrets" '{"v":1,"ssh_keys":["ssh-ed25519 AAAA unit-a"],"wifi":{"ssid":"Jo'"'"'s Solar","key":"it'"'"'s-a-key"}}'
RC=0; run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 14: exits 0"
assert_contains "wireless.default_radio0.ssid=Jo's Solar" "$(cat "$T/uci.state")" "case 14: SSID with quote"
assert_contains "wireless.default_radio1.key=it's-a-key" "$(cat "$T/uci.state")" "case 14: key with quote"
rm -rf "$T"

# --- Case 15: boot medium is read from /proc/mounts, failing towards NAND ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
run_boot "$T" "$MOUNTS_NOR_TMPFS" >/dev/null 2>&1 || true
assert_contains 'dropbear.@dropbear[0].enable=1' "$(cat "$T/uci.state")" "case 15: tmpfs root is NOR"
rm -rf "$T"
T=$(mktemp -d); make_sandbox "$T"
run_boot "$T" "$MOUNTS_NOR" env SOLARMATRIX_MOUNTS="$T/no-such-mounts" >/dev/null 2>&1 || true
assert_contains 'dropbear.@dropbear[0].enable=0' "$(cat "$T/uci.state")" "case 15: unreadable mounts is NAND"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 15: unreadable mounts accepts no key"
rm -rf "$T"

# --- Case 16: the shipped dropbear config is closed until the script opens it ---
CASES=$((CASES + 1))
CFG="$(cat "$DROPBEAR_CONFIG" 2>/dev/null)"
assert_eq 1 "$(grep -c '^config dropbear' "$DROPBEAR_CONFIG" 2>/dev/null)" "case 16: exactly one dropbear section"
assert_contains "option enable '0'" "$CFG" "case 16: disabled by default"
assert_contains "option PasswordAuth 'off'" "$CFG" "case 16: password auth off"
assert_contains "option RootPasswordAuth 'off'" "$CFG" "case 16: root password auth off"
assert_contains "option DirectInterface 'lan'" "$CFG" "case 16: bound to lan"
assert_contains "option Port '22'" "$CFG" "case 16: port 22"
assert_eq 1 "$(grep -c "option enable" "$DROPBEAR_CONFIG" 2>/dev/null)" "case 16: no second enable line"

# --- Case 17: NOR does not enable dropbear unless the key-only settings took ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
RC=0; run_boot "$T" "$MOUNTS_NOR" env UCI_FAIL_KEY='dropbear.@dropbear[0].PasswordAuth' >/dev/null 2>&1 || RC=$?
STATE="$(cat "$T/uci.state")"
assert_nonzero "$RC" "case 17: exits non-zero"
assert_not_contains 'dropbear.@dropbear[0].enable=1' "$STATE" "case 17: dropbear not enabled"
assert_contains 'dropbear.@dropbear[0].enable=0' "$STATE" "case 17: dropbear left disabled"
assert_contains 'PasswordAuth' "$(cat "$T/logger.log")" "case 17: log names the setting"
rm -rf "$T"

# --- Case 18: the shadow temp file is never world- or group-readable ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"
run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || true
MODES="$(cat "$T/shadow-mode.log" 2>/dev/null)"
assert_contains '-rw-------' "$MODES" "case 18: temp file created 0600"
assert_not_contains 'r--' "$MODES" "case 18: temp file not readable by others"
assert_eq 'root:*:19000:0:99999:7:::' "$(sed -n 1p "$T/shadow")" "case 18: root field still rewritten"
assert_eq '' "$(ls "$T"/shadow.* 2>/dev/null)" "case 18: no temp file left behind"
rm -rf "$T"

# --- Case 19: WiFi values that could inject UCI commands are refused ---
for field in ssid key; do
    CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; wifi_sections "$T"
    if [ "$field" = ssid ]; then
        WIFI='"ssid":"Evil\nset dropbear.@dropbear[0].enable=1","key":"s3cret-wifi"'
    else
        WIFI='"ssid":"SolarMatrix-1","key":"s3cret-wifi\nset dropbear.@dropbear[0].enable=1"'
    fi
    make_secrets "$T/secrets" '{"v":1,"ssh_keys":["ssh-ed25519 AAAA unit-a"],"wifi":{'"$WIFI"'}}'
    RC=0; run_boot "$T" "$MOUNTS_NAND" >/dev/null 2>&1 || RC=$?
    STATE="$(cat "$T/uci.state")"
    assert_nonzero "$RC" "case 19 ($field): exits non-zero"
    assert_not_contains 'dropbear.@dropbear[0].enable=1' "$STATE" "case 19 ($field): no injected setting"
    assert_not_contains 'wireless.default_radio0.ssid' "$STATE" "case 19 ($field): no SSID written"
    assert_not_contains 'wireless.default_radio0.key' "$STATE" "case 19 ($field): no key written"
    assert_contains 'wireless.default_radio0.disabled=1' "$STATE" "case 19 ($field): APs down"
    assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 19 ($field): logged"
    rm -rf "$T"
done

# --- Case 20: WiFi length and charset limits ---
# check_wifi SSID KEY WANT: WANT is up or down.
check_wifi() {
    local want="$3" t
    CASES=$((CASES + 1)); t=$(mktemp -d); make_sandbox "$t"; wifi_sections "$t"
    make_secrets "$t/secrets" '{"v":1,"ssh_keys":["ssh-ed25519 AAAA unit-a"],"wifi":{"ssid":"'"$1"'","key":"'"$2"'"}}'
    run_boot "$t" "$MOUNTS_NAND" >/dev/null 2>&1 || true
    if [ "$want" = up ]; then
        assert_contains 'wireless.default_radio0.disabled=0' "$(cat "$t/uci.state")" "case 20: ssid '$1' key '$2' accepted"
    else
        assert_contains 'wireless.default_radio0.disabled=1' "$(cat "$t/uci.state")" "case 20: ssid '$1' key '$2' refused"
        assert_not_contains 'wireless.default_radio0.ssid' "$(cat "$t/uci.state")" "case 20: ssid '$1' key '$2' not written"
    fi
    rm -rf "$t"
}
S32="$(printf 'a%.0s' $(seq 32))"; S33="${S32}a"
K8='12345678'; K7='1234567'; K63="$(printf 'k%.0s' $(seq 63))"
HEX64="$(printf 'aF%.0s' $(seq 32))"; NONHEX64="$(printf 'g%.0s' $(seq 64))"
check_wifi "$S32" "$K8" up
check_wifi "$S33" "$K8" down
check_wifi 'Tab\there' "$K8" down
check_wifi 'ok' "$K63" up
check_wifi 'ok' "$K7" down
check_wifi 'ok' "$HEX64" up
check_wifi 'ok' "$NONHEX64" down
check_wifi 'ok' 'café-key' down

# --- Case 21: unprovisioned but the provisioning key file is missing ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; rm -f "$T/provisioning.pub"
RC=0; run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 21: exits non-zero"
assert_eq '' "$(cat "$T/etc/dropbear/authorized_keys")" "case 21: no key accepted"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 21: logged at daemon.crit"
rm -rf "$T"

# --- Case 22: valid secrets with keys but incomplete WiFi ---
CASES=$((CASES + 1)); T=$(mktemp -d); make_sandbox "$T"; wifi_sections "$T"
make_secrets "$T/secrets" '{"v":1,"ssh_keys":["ssh-ed25519 AAAA unit-a"],"wifi":{"ssid":"SolarMatrix-1"}}'
RC=0; run_boot "$T" "$MOUNTS_NOR" >/dev/null 2>&1 || RC=$?
STATE="$(cat "$T/uci.state")"
assert_nonzero "$RC" "case 22: exits non-zero"
assert_eq 'ssh-ed25519 AAAA unit-a' "$(cat "$T/etc/dropbear/authorized_keys")" "case 22: unit key still installed"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 22: logged at daemon.crit"
assert_contains 'wireless.default_radio0.disabled=1' "$STATE" "case 22: APs down"
assert_contains 'wireless.default_radio1.disabled=1' "$STATE" "case 22: both APs down"
assert_not_contains 'wireless.default_radio0.ssid' "$STATE" "case 22: no SSID written"
rm -rf "$T"

finish

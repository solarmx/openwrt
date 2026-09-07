#!/bin/bash
# Tests for the SolarMatrix device hardening scripts shipped in
# solarmatrix/files/. Each case builds a sandbox with fake uci/service/logger/
# mount/jsonfilter/chpasswd binaries on PATH, runs a script, and asserts on the
# resulting UCI state, log lines and side effects. No device needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BOOT_HARDENING="$HERE/files/etc/uci-defaults/99-solarmatrix-hardening"
HARDEN_SSH="$HERE/files/sbin/solarmatrix-harden-ssh"

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

assert_not_contains() {
    local needle="$1" haystack="$2" msg="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL: $msg"
            echo "  unexpected needle: $needle"
            echo "  haystack:          $haystack"
            FAIL=$((FAIL + 1))
            ;;
    esac
}

assert_nonzero() {
    local rc="$1" msg="$2"
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: $msg (exited 0)"
        FAIL=$((FAIL + 1))
    fi
}

# Builds a sandbox in $1 with fake tools on PATH.
#   $1/uci.state    UCI state as "key=value" lines
#   $1/uci.commits  committed package names
#   $1/service.log  service invocations
#   $1/logger.log   logger invocations
#   $1/chpasswd.log what was piped to chpasswd
#   $1/harden.log   invocations of the (faked) harden-ssh script
#   $1/nvme/        what the NVMe presents once "mounted"
make_sandbox() {
    local t="$1"
    mkdir -p "$t/bin" "$t/nvme"
    : > "$t/uci.state"
    : > "$t/uci.commits"
    : > "$t/service.log"
    : > "$t/logger.log"
    : > "$t/chpasswd.log"
    : > "$t/harden.log"

    cat > "$t/bin/uci" <<'UCI'
#!/bin/sh
while [ "$1" = "-q" ]; do shift; done
cmd="$1"; shift
case "$cmd" in
set)
    key="${1%%=*}"; val="${1#*=}"
    [ "${UCI_READONLY:-0}" = "1" ] && exit 0
    [ "$key" = "${UCI_FAIL_KEY:-}" ] && exit 0
    awk -F= -v k="$key" '$1!=k' "$UCI_STATE" > "$UCI_STATE.new"
    mv "$UCI_STATE.new" "$UCI_STATE"
    printf '%s=%s\n' "$key" "$val" >> "$UCI_STATE"
    ;;
get)
    awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; found=1 } END { exit !found }' "$UCI_STATE" || exit 1
    ;;
show)
    grep -q "^$1\." "$UCI_STATE" || exit 1
    grep "^$1\." "$UCI_STATE"
    ;;
commit)
    printf '%s\n' "$1" >> "$UCI_COMMITS"
    ;;
*)
    echo "fake uci: unsupported command '$cmd'" >&2
    exit 2
    ;;
esac
exit 0
UCI

    cat > "$t/bin/service" <<'SVC'
#!/bin/sh
printf '%s\n' "$*" >> "$SERVICE_LOG"
[ "$*" = "${SERVICE_FAIL:-}" ] && exit 1
exit 0
SVC

    cat > "$t/bin/logger" <<'LOG'
#!/bin/sh
printf '%s\n' "$*" >> "$LOGGER_LOG"
exit 0
LOG

    # The script mounts read-only and expects the NVMe contents to appear at the
    # mountpoint; the sandbox mountpoint is already populated, so this only has
    # to succeed or fail on command.
    cat > "$t/bin/mount" <<'MNT'
#!/bin/sh
[ "${MOUNT_FAIL:-0}" = "1" ] && exit 1
exit 0
MNT

    cat > "$t/bin/umount" <<'UMNT'
#!/bin/sh
exit 0
UMNT

    cat > "$t/bin/jsonfilter" <<'JF'
#!/bin/sh
# Supports the one form the script uses: jsonfilter -i FILE -e '@.field'
file=''; expr=''
while [ $# -gt 0 ]; do
    case "$1" in
        -i) file="$2"; shift 2 ;;
        -e) expr="$2"; shift 2 ;;
        *) shift ;;
    esac
done
field="${expr#@.}"
val="$(sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file")"
[ -n "$val" ] || exit 1
printf '%s\n' "$val"
JF

    cat > "$t/bin/chpasswd" <<'CHP'
#!/bin/sh
cat >> "$CHPASSWD_LOG"
[ "${CHPASSWD_FAIL:-0}" = "1" ] && exit 1
exit 0
CHP

    # Faked so the boot script's decision is what is under test here; the real
    # harden-ssh script has its own cases below.
    cat > "$t/bin/solarmatrix-harden-ssh" <<'HRD'
#!/bin/sh
printf 'called\n' >> "$HARDEN_LOG"
exit 0
HRD

    chmod 755 "$t"/bin/*
}

run_boot() {
    local t="$1"; shift
    env PATH="$t/bin:$PATH" \
        UCI_STATE="$t/uci.state" \
        UCI_COMMITS="$t/uci.commits" \
        SERVICE_LOG="$t/service.log" \
        LOGGER_LOG="$t/logger.log" \
        CHPASSWD_LOG="$t/chpasswd.log" \
        HARDEN_LOG="$t/harden.log" \
        SOLARMATRIX_NVME_DEV="$t/nvme.dev" \
        SOLARMATRIX_NVME_MNT="$t/nvme" \
        SOLARMATRIX_NVME_WAIT=1 \
        "$@" "$BOOT_HARDENING"
}

run_harden() {
    local t="$1"; shift
    env PATH="$t/bin:$PATH" \
        UCI_STATE="$t/uci.state" \
        UCI_COMMITS="$t/uci.commits" \
        SERVICE_LOG="$t/service.log" \
        LOGGER_LOG="$t/logger.log" \
        "$@" "$HARDEN_SSH"
}

# Marks the sandbox NVMe as present and provisioned to the given degree.
nvme_present() { touch "$1/nvme.dev"; }
nvme_config()  { printf '{\n  "serial": "s",\n  "root_password": "%s"\n}\n' "$2" > "$1/nvme/config.json"; }
nvme_marker()  { touch "$1/nvme/.provisioned"; }

# =============== boot-time hardening script ===============

# --- Case 1: binds dropbear to the LAN bridge ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
run_boot "$T" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 1: exits 0"
assert_contains 'dropbear.@dropbear[0].DirectInterface=lan' "$(cat "$T/uci.state")" \
    "case 1: dropbear bound to the lan interface"
assert_contains 'dropbear' "$(cat "$T/uci.commits")" "case 1: dropbear config committed"
rm -rf "$T"

# --- Case 2: an unprovisioned device keeps password auth on ---
# The provisioning tool still has to reach root over the LAN.
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
run_boot "$T" >/dev/null 2>&1 || true
assert_not_contains 'PasswordAuth' "$(cat "$T/uci.state")" \
    "case 2: password authentication untouched with no config.json"
assert_eq '' "$(cat "$T/harden.log")" "case 2: harden-ssh not run on an unprovisioned device"
rm -rf "$T"

# --- Case 3: uhttpd taken off the wildcard socket ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
printf 'uhttpd.main.listen_http=0.0.0.0:80\n' >> "$T/uci.state"
run_boot "$T" >/dev/null 2>&1 || true
assert_contains 'uhttpd disable' "$(cat "$T/service.log")" "case 3: uhttpd disabled when present"
rm -rf "$T"

# --- Case 4: succeeds on an image without uhttpd ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
run_boot "$T" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 4: exits 0 without uhttpd installed"
assert_not_contains 'uhttpd' "$(cat "$T/service.log")" "case 4: no service touched without uhttpd"
rm -rf "$T"

# --- Case 5: a setting that does not take is logged, and does not skip the rest ---
# This script runs unattended with nobody reading its exit code, so failing
# silently open is the one outcome it must never have.
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
printf 'uhttpd.main.listen_http=0.0.0.0:80\n' >> "$T/uci.state"
RC=0
run_boot "$T" env UCI_FAIL_KEY='dropbear.@dropbear[0].DirectInterface' >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 5: exits non-zero so the script runs again next boot"
LOGGED="$(cat "$T/logger.log")"
assert_contains 'daemon.crit' "$LOGGED" "case 5: failure logged at daemon.crit"
assert_contains 'DirectInterface' "$LOGGED" "case 5: log names the setting that did not take"
assert_contains 'uhttpd disable' "$(cat "$T/service.log")" \
    "case 5: the uhttpd concern still runs after the dropbear concern failed"
rm -rf "$T"

# --- Case 6: the provisioning window is wired-only ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
printf 'wireless.default_radio0=wifi-iface\nwireless.default_radio1=wifi-iface\n' >> "$T/uci.state"
run_boot "$T" >/dev/null 2>&1 || true
STATE="$(cat "$T/uci.state")"
assert_contains 'wireless.default_radio0.disabled=1' "$STATE" "case 6: 2.4 GHz AP down"
assert_contains 'wireless.default_radio1.disabled=1' "$STATE" "case 6: 5 GHz AP down"
rm -rf "$T"

# --- Case 7: mid-provisioning -- password applied, SSH still open ---
# Closes the window between `sysupgrade -n` (which wipes /etc/shadow) and the
# factory reset that used to be the first thing to set a root password.
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
nvme_present "$T"; nvme_config "$T" "correct-horse-battery-staple"
RC=0
run_boot "$T" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 7: exits 0"
assert_eq 'root:correct-horse-battery-staple' "$(cat "$T/chpasswd.log")" \
    "case 7: root password applied from config.json"
assert_eq '' "$(cat "$T/harden.log")" "case 7: SSH left open for the rest of the provisioning run"
assert_not_contains 'wireless' "$(cat "$T/uci.state")" \
    "case 7: WiFi left alone once there is a password protecting the device"
rm -rf "$T"

# --- Case 8: a provisioned device locks SSH again after a config wipe ---
# This is the five-second reset-button case: factoryreset -y wipes the overlay,
# taking /etc/config/dropbear and /etc/shadow with it.
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
nvme_present "$T"; nvme_config "$T" "correct-horse-battery-staple"; nvme_marker "$T"
RC=0
run_boot "$T" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 8: exits 0"
assert_eq 'root:correct-horse-battery-staple' "$(cat "$T/chpasswd.log")" \
    "case 8: root password restored from config.json"
assert_contains 'called' "$(cat "$T/harden.log")" \
    "case 8: password authentication disabled again"
rm -rf "$T"

# --- Case 9: fails closed when the password cannot be applied ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
nvme_present "$T"; nvme_config "$T" "correct-horse-battery-staple"
RC=0
run_boot "$T" env CHPASSWD_FAIL=1 >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 9: exits non-zero"
assert_contains 'called' "$(cat "$T/harden.log")" \
    "case 9: SSH locked rather than left open with no root password"
assert_contains 'daemon.crit' "$(cat "$T/logger.log")" "case 9: logged at daemon.crit"
rm -rf "$T"

# --- Case 10: fails closed when config.json carries no root_password ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
nvme_present "$T"; printf '{ "serial": "s" }\n' > "$T/nvme/config.json"
RC=0
run_boot "$T" >/dev/null 2>&1 || RC=$?
assert_nonzero "$RC" "case 10: exits non-zero"
assert_contains 'called' "$(cat "$T/harden.log")" "case 10: SSH locked"
rm -rf "$T"

# --- Case 11: an unmountable NVMe leaves an unprovisioned device alone ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
nvme_present "$T"
RC=0
run_boot "$T" env MOUNT_FAIL=1 >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 11: exits 0"
assert_eq '' "$(cat "$T/harden.log")" "case 11: nothing to protect, nothing locked"
assert_eq '' "$(cat "$T/chpasswd.log")" "case 11: no password applied"
rm -rf "$T"

# =============== harden-ssh script ===============

# --- Case 12: turns off root password authentication ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
run_harden "$T" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 12: exits 0"
STATE=$(cat "$T/uci.state")
assert_contains 'dropbear.@dropbear[0].PasswordAuth=off' "$STATE" "case 12: password auth off"
assert_contains 'dropbear.@dropbear[0].RootPasswordAuth=off' "$STATE" "case 12: root password auth off"
assert_contains 'dropbear.@dropbear[0].DirectInterface=lan' "$STATE" "case 12: still bound to lan"
assert_contains 'dropbear restart' "$(cat "$T/service.log")" "case 12: dropbear restarted"
rm -rf "$T"

# --- Case 13: fails loudly when the setting does not take ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
OUT=$(run_harden "$T" env UCI_READONLY=1 2>&1) || RC=$?
assert_nonzero "$RC" "case 13: exits non-zero when uci does not persist"
assert_contains "dropbear PasswordAuth is '(unset)', expected 'off'" "$OUT" \
    "case 13: error names the option that did not take"
rm -rf "$T"

# --- Case 14: idempotent ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
run_harden "$T" >/dev/null 2>&1 || true
RC=0
run_harden "$T" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 14: second run exits 0"
assert_eq 1 "$(grep -c 'RootPasswordAuth=off' "$T/uci.state")" \
    "case 14: option written exactly once"
rm -rf "$T"

# --- Case 15: a failed restart does not fail a correctly configured device ---
# The boot script calls this before the lan interface is up, where dropbear's
# init script legitimately returns non-zero. Failing here would report a device
# as unhardened when its configuration is exactly right.
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
run_harden "$T" env SERVICE_FAIL='dropbear restart' >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 15: exits 0 when only the restart failed"
assert_contains 'dropbear.@dropbear[0].PasswordAuth=off' "$(cat "$T/uci.state")" \
    "case 15: settings still committed"
assert_contains 'daemon.warn' "$(cat "$T/logger.log")" "case 15: restart failure logged"
rm -rf "$T"

# --- Case 16: neither script ever discloses a credential ---
CASES=$((CASES + 1))
BODY="$(cat "$BOOT_HARDENING" "$HARDEN_SSH")"
assert_not_contains 'logger -t solarmatrix-hardening -p daemon.crit "$root_password' "$BODY" \
    "case 16: the root password is never logged"
assert_not_contains 'echo "$root_password' "$BODY" "case 16: the root password is never echoed"
# It reaches chpasswd on stdin, never in argv, so it cannot show up in ps output.
assert_contains '| chpasswd' "$BODY" \
    'case 16: the password is piped to chpasswd'
assert_not_contains 'chpasswd "' "$BODY" \
    'case 16: the password is never passed to chpasswd as an argument'

echo
if [ $FAIL -eq 0 ]; then
    echo "PASS: $CASES cases"
    exit 0
fi
echo "FAILED: $FAIL assertion(s) across $CASES cases"
exit 1

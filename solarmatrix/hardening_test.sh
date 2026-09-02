#!/bin/bash
# Tests for the SolarMatrix device hardening scripts shipped in
# solarmatrix/files/. Each case builds a sandbox with a fake `uci` and a fake
# `service` on PATH, runs a script, and asserts on the resulting UCI state.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UCI_DEFAULTS="$HERE/files/etc/uci-defaults/99-solarmatrix-hardening"
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

# Builds a sandbox in $1 with fake uci/service binaries on PATH.
# UCI state lives in $1/uci.state as "key=value" lines, commits are appended
# to $1/uci.commits, service invocations to $1/service.log.
make_sandbox() {
    local t="$1"
    mkdir -p "$t/bin"
    : > "$t/uci.state"
    : > "$t/uci.commits"
    : > "$t/service.log"

    cat > "$t/bin/uci" <<'UCI'
#!/bin/sh
while [ "$1" = "-q" ]; do shift; done
cmd="$1"; shift
case "$cmd" in
set)
    [ "${UCI_READONLY:-0}" = "1" ] && exit 0
    key="${1%%=*}"; val="${1#*=}"
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
exit 0
SVC

    chmod 755 "$t/bin/uci" "$t/bin/service"
}

run_in_sandbox() {
    local t="$1"; shift
    env PATH="$t/bin:$PATH" \
        UCI_STATE="$t/uci.state" \
        UCI_COMMITS="$t/uci.commits" \
        SERVICE_LOG="$t/service.log" \
        "$@"
}

# --- Case 1: uci-defaults binds dropbear to the LAN bridge ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
run_in_sandbox "$T" "$UCI_DEFAULTS" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 1: uci-defaults exits 0"
assert_contains 'dropbear.@dropbear[0].DirectInterface=lan' "$(cat "$T/uci.state")" \
    "case 1: dropbear bound to the lan interface"
assert_contains 'dropbear' "$(cat "$T/uci.commits")" "case 1: dropbear config committed"
rm -rf "$T"

# --- Case 2: uci-defaults leaves password auth alone (provisioning needs it) ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
run_in_sandbox "$T" "$UCI_DEFAULTS" >/dev/null 2>&1 || true
assert_not_contains 'PasswordAuth' "$(cat "$T/uci.state")" \
    "case 2: first boot does not touch password authentication"
rm -rf "$T"

# --- Case 3: uci-defaults takes uhttpd off the WAN-facing wildcard socket ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
printf 'uhttpd.main.listen_http=0.0.0.0:80\n' >> "$T/uci.state"
run_in_sandbox "$T" "$UCI_DEFAULTS" >/dev/null 2>&1 || true
assert_contains 'uhttpd disable' "$(cat "$T/service.log")" \
    "case 3: uhttpd disabled when present"
rm -rf "$T"

# --- Case 4: uci-defaults succeeds on an image without uhttpd ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
run_in_sandbox "$T" "$UCI_DEFAULTS" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 4: uci-defaults exits 0 without uhttpd installed"
assert_eq '' "$(cat "$T/service.log")" "case 4: no service touched without uhttpd installed"
rm -rf "$T"

# --- Case 5: harden-ssh turns off root password authentication ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
OUT=$(run_in_sandbox "$T" "$HARDEN_SSH" 2>&1) || RC=$?
assert_eq 0 "$RC" "case 5: harden-ssh exits 0"
STATE=$(cat "$T/uci.state")
assert_contains 'dropbear.@dropbear[0].PasswordAuth=off' "$STATE" \
    "case 5: password auth off"
assert_contains 'dropbear.@dropbear[0].RootPasswordAuth=off' "$STATE" \
    "case 5: root password auth off"
assert_contains 'dropbear.@dropbear[0].DirectInterface=lan' "$STATE" \
    "case 5: still bound to lan"
assert_contains 'dropbear' "$(cat "$T/uci.commits")" "case 5: dropbear config committed"
assert_contains 'dropbear restart' "$(cat "$T/service.log")" "case 5: dropbear restarted"
rm -rf "$T"

# --- Case 6: harden-ssh fails loudly when the setting does not take ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
RC=0
OUT=$(run_in_sandbox "$T" env UCI_READONLY=1 "$HARDEN_SSH" 2>&1) || RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL: case 6: harden-ssh must exit non-zero when uci does not persist"; FAIL=$((FAIL + 1)); }
assert_contains "dropbear PasswordAuth is '(unset)', expected 'off'" "$OUT" \
    "case 6: error names the option that did not take"
rm -rf "$T"

# --- Case 7: harden-ssh is idempotent ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
run_in_sandbox "$T" "$HARDEN_SSH" >/dev/null 2>&1 || true
RC=0
run_in_sandbox "$T" "$HARDEN_SSH" >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "case 7: second run exits 0"
assert_eq 1 "$(grep -c 'RootPasswordAuth=off' "$T/uci.state")" \
    "case 7: option written exactly once"
rm -rf "$T"

# --- Case 8: neither script ever prints or stores a credential ---
CASES=$((CASES + 1))
T=$(mktemp -d); make_sandbox "$T"
BODY="$(cat "$UCI_DEFAULTS" "$HARDEN_SSH")"
assert_not_contains 'chpasswd' "$BODY" "case 8: hardening never sets a password"
assert_not_contains 'passwd' "$BODY" "case 8: hardening never reads or writes passwords"
rm -rf "$T"

echo
if [ $FAIL -eq 0 ]; then
    echo "PASS: $CASES cases"
    exit 0
fi
echo "FAILED: $FAIL assertion(s) across $CASES cases"
exit 1

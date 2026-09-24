#!/bin/bash
# Shared helpers for the solarmatrix/*_test.sh suites. Sourced, not run.
export LC_ALL=C

FAIL=0
CASES=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $msg"; echo "  expected: $expected"; echo "  actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *) echo "FAIL: $msg"; echo "  needle:   $needle"; echo "  haystack: $haystack"
           FAIL=$((FAIL + 1)) ;;
    esac
}

assert_not_contains() {
    local needle="$1" haystack="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL: $msg"; echo "  unexpected: $needle"; echo "  haystack:   $haystack"
                     FAIL=$((FAIL + 1)) ;;
    esac
}

assert_nonzero() {
    if [ "$1" -eq 0 ]; then echo "FAIL: $2 (exited 0)"; FAIL=$((FAIL + 1)); fi
}

# Pads FILE with 0xFF up to the 128 KiB partition size.
pad_secrets() {
    local f="$1" size
    size=$(wc -c < "$f" | tr -d ' ')
    head -c $((131072 - size)) /dev/zero | tr '\000' '\377' >> "$f"
}

# Writes a valid factory-secrets image holding JSON.
make_secrets() {
    local f="$1" json="$2" len sum
    len=$(printf '%s' "$json" | wc -c | tr -d ' ')
    sum=$(printf '%s' "$json" | shasum -a 256 | cut -d' ' -f1)
    { printf 'SMFS1 %s %s\n' "$len" "$sum"; printf '%s' "$json"; } > "$f"
    pad_secrets "$f"
}

# Writes an erased (all 0xFF) factory-secrets image.
make_empty_secrets() {
    : > "$1"
    pad_secrets "$1"
}

# A stand-in for OpenWrt's jsonfilter supporting the forms the scripts use:
#   jsonfilter -s JSON -e '@.a.b'   and   jsonfilter -s JSON -e '@.list[*]'
install_fake_jsonfilter() {
    cat > "$1/jsonfilter" <<'PY'
#!/usr/bin/env python3
import json, sys
args, src, expr, i = sys.argv[1:], None, None, 0
while i < len(args):
    if args[i] == '-s': src = args[i + 1]; i += 2
    elif args[i] == '-i': src = open(args[i + 1]).read(); i += 2
    elif args[i] == '-e': expr = args[i + 1]; i += 2
    else: i += 1
try:
    node = json.loads(src)
except Exception:
    sys.exit(1)
path = expr[2:] if expr and expr.startswith('@.') else ''
star = path.endswith('[*]')
if star:
    path = path[:-3]
for part in [p for p in path.split('.') if p]:
    if not isinstance(node, dict) or part not in node:
        sys.exit(1)
    node = node[part]
if star:
    if not isinstance(node, list) or not node:
        sys.exit(1)
    for v in node:
        print(v)
elif isinstance(node, (dict, list)):
    print(json.dumps(node))
else:
    print(node)
PY
    chmod 755 "$1/jsonfilter"
}

finish() {
    echo
    if [ $FAIL -eq 0 ]; then echo "PASS: $CASES cases"; exit 0; fi
    echo "FAILED: $FAIL assertion(s) across $CASES cases"; exit 1
}

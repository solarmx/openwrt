#!/bin/bash
# Tests for files/lib/solarmatrix/secrets.sh. No device needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/testlib.sh"
LIB="$HERE/files/lib/solarmatrix/secrets.sh"

JSON='{"v":1,"serial":"SM-0001","ssh_keys":["ssh-ed25519 AAAA test"],"nvme_key":"'"$(printf 'ab%.0s' $(seq 32))"'"}'

state() { sh -c ". '$LIB'; sm_secrets_state '$1'"; }
payload() { sh -c ". '$LIB'; sm_secrets_json '$1'"; }

T=$(mktemp -d)

# --- Case 1: an erased partition is empty ---
CASES=$((CASES + 1))
make_empty_secrets "$T/p"
assert_eq empty "$(state "$T/p")" "case 1: erased partition reads as empty"

# --- Case 2: a correct image is valid and returns its JSON ---
CASES=$((CASES + 1))
make_secrets "$T/p" "$JSON"
assert_eq valid "$(state "$T/p")" "case 2: valid image"
assert_eq "$JSON" "$(payload "$T/p")" "case 2: payload returned byte for byte"

# --- Case 3: one flipped payload byte is corrupt, and yields no payload ---
CASES=$((CASES + 1))
make_secrets "$T/p" "$JSON"
printf 'X' | dd of="$T/p" bs=1 seek=100 conv=notrunc 2>/dev/null
assert_eq corrupt "$(state "$T/p")" "case 3: flipped byte is corrupt"
RC=0; OUT=$(payload "$T/p") || RC=$?
assert_nonzero "$RC" "case 3: no payload from a corrupt image"
assert_eq '' "$OUT" "case 3: corrupt image prints nothing"

# --- Case 4: a write cut short is corrupt, never empty or valid ---
# Header and the first 20 payload bytes made it to flash; the rest is erased.
CASES=$((CASES + 1))
make_secrets "$T/full" "$JSON"
HDR_LEN=$(head -n 1 "$T/full" | wc -c | tr -d ' ')
head -c $((HDR_LEN + 20)) "$T/full" > "$T/p"; pad_secrets "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 4: half-written image is corrupt"

# --- Case 5: wrong magic is corrupt ---
CASES=$((CASES + 1))
make_secrets "$T/p" "$JSON"
printf 'SMFS9' | dd of="$T/p" bs=1 seek=0 conv=notrunc 2>/dev/null
assert_eq corrupt "$(state "$T/p")" "case 5: wrong magic"

# --- Case 6: a length beyond the partition is corrupt ---
CASES=$((CASES + 1))
{ printf 'SMFS1 999999 %064d\n' 0; } > "$T/p"; pad_secrets "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 6: oversized length"

# --- Case 7: a non-numeric length is corrupt ---
CASES=$((CASES + 1))
{ printf 'SMFS1 12a %064d\n' 0; } > "$T/p"; pad_secrets "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 7: non-numeric length"

# --- Case 8: a missing device is corrupt, so callers fail closed ---
CASES=$((CASES + 1))
assert_eq corrupt "$(state "$T/does-not-exist")" "case 8: missing partition"

# --- Case 9: an unreadable device is corrupt too ---
CASES=$((CASES + 1))
make_secrets "$T/locked" "$JSON"; chmod 000 "$T/locked"
if [ -r "$T/locked" ]; then
    echo "note: case 9 skipped, running as root"
else
    assert_eq corrupt "$(state "$T/locked")" "case 9: unreadable partition"
fi
chmod 600 "$T/locked"

# --- Case 10: an overflowing length cannot pass as an empty payload ---
# The digest is SHA-256 of the empty string, so only the length check
# stands between this header and "valid".
CASES=$((CASES + 1))
{ printf 'SMFS1 99999999999999999999 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n'; } > "$T/p"; pad_secrets "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 10: overflowing length"

# --- Case 11: sm_secrets_dev finds the partition by label in /proc/mtd ---
CASES=$((CASES + 1))
RC=0; OUT=$(sh -c ". '$LIB'; SOLARMATRIX_SECRETS_DEV='' sm_secrets_dev" 2>/dev/null) || RC=$?
case "$(uname)" in
    Linux) ;;  # a real /proc/mtd may or may not have it; nothing to assert
    *) assert_eq '' "$OUT" "case 11: no /proc/mtd on macOS, so nothing is found"
       assert_eq 1 "$RC" "case 11: not found returns 1" ;;
esac
OUT=$(sh -c ". '$LIB'; SOLARMATRIX_SECRETS_DEV=/dev/mtd9 sm_secrets_dev")
assert_eq /dev/mtd9 "$OUT" "case 11: override honoured"

# --- Cases 12-17: short, unreadable or not-fully-erased reads are corrupt ---
# "empty" reopens the provisioning key, so it needs positive proof: all
# 131072 bytes read back, every one 0xFF.
CASES=$((CASES + 1))
: > "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 12: zero-length read"

CASES=$((CASES + 1))
head -c 8 /dev/zero | tr '\000' '\377' > "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 13: 8 erased bytes only (truncated partition)"

CASES=$((CASES + 1))
mkdir "$T/dir"
assert_eq corrupt "$(state "$T/dir" 2>/dev/null)" "case 14: directory passed as DEV"

CASES=$((CASES + 1))
assert_eq corrupt "$(state '')" "case 15: empty DEV argument"

# An interrupted re-erase: block 0 erased, block 1 still holds old data.
CASES=$((CASES + 1))
head -c 65536 /dev/zero | tr '\000' '\377' > "$T/p"
head -c 65536 /dev/zero | tr '\000' 'A' >> "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 16: first block erased, second not"

# The write stopped inside the header itself.
CASES=$((CASES + 1))
make_secrets "$T/full" "$JSON"
head -c 40 "$T/full" > "$T/p"; pad_secrets "$T/p"
assert_eq corrupt "$(state "$T/p")" "case 17: header cut short"

# --- Case 18: glob characters in the header are never expanded ---
# If "1?" were globbed it would match the file "12" in the working
# directory and turn into a length that makes the image hash-valid.
CASES=$((CASES + 1))
G='{"v":123456}'
GSUM=$(printf '%s' "$G" | shasum -a 256 | cut -d' ' -f1)
{ printf 'SMFS1 1? %s\n' "$GSUM"; printf '%s' "$G"; } > "$T/p"; pad_secrets "$T/p"
mkdir "$T/cwd"; : > "$T/cwd/12"
assert_eq corrupt "$(cd "$T/cwd" && state "$T/p")" "case 18: glob in length is corrupt"
RC=0; OUT=$(cd "$T/cwd" && payload "$T/p") || RC=$?
assert_nonzero "$RC" "case 18: no payload through a glob header"
assert_eq '' "$OUT" "case 18: glob header prints nothing"
{ printf 'SMFS1 * %s\n' "$GSUM"; printf '%s' "$G"; } > "$T/p"; pad_secrets "$T/p"
assert_eq corrupt "$(cd "$T/cwd" && state "$T/p")" "case 18: star in length is corrupt"

# --- Case 19: sm_secrets_dev reads the partition table from SOLARMATRIX_MTD ---
CASES=$((CASES + 1))
{
    printf 'dev:    size   erasesize  name\n'
    printf 'mtd4: 000a0000 00010000 "factory"\n'
    printf 'mtd5: 00020000 00010000 "factory-secrets"\n'
} > "$T/mtd"
OUT=$(sh -c ". '$LIB'; SOLARMATRIX_MTD='$T/mtd' sm_secrets_dev")
assert_eq /dev/mtd5 "$OUT" "case 19: found by label"
printf 'mtd4: 000a0000 00010000 "factory"\n' > "$T/mtd"
RC=0; OUT=$(sh -c ". '$LIB'; SOLARMATRIX_MTD='$T/mtd' sm_secrets_dev") || RC=$?
assert_eq 1 "$RC" "case 19: image without the split returns 1"
assert_eq '' "$OUT" "case 19: and prints nothing"

rm -rf "$T"
finish

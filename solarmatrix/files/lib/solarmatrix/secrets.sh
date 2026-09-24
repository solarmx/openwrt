# SPDX-License-Identifier: GPL-2.0-or-later
#
# Reader for the factory-secrets NOR partition: the free 128 KiB tail of the
# stock factory partition, split off in the DTS so the MACs and WiFi
# calibration before it stay read-only. Written once per unit by the
# provisioning tool. Layout:
#
#   SMFS1 <len> <sha256-hex>\n   header, ASCII, at most 128 bytes
#   <len bytes of JSON>          payload
#   0xFF ...                     erased remainder
#
# States:
#   empty    all 131072 bytes read back and every one is 0xFF: an
#            unprovisioned unit. A short read, a read error or a partly
#            erased partition (e.g. a re-erase cut off after block 0) is
#            not empty, because empty reopens the provisioning key.
#   valid    the header is exactly "SMFS1 <len> <sha256>", <len> payload
#            bytes read back and their SHA-256 matches
#   corrupt  anything else, including a missing or unreadable partition.
#            Callers fail closed on it: a write cut short must never reopen
#            the provisioning key.
#
# Sourced by the boot hardening and storage scripts. Prints nothing secret
# except through sm_secrets_json, whose output callers must not log.

SM_SECRETS_MAGIC='SMFS1'
SM_SECRETS_SIZE=131072
SM_SECRETS_HDR_MAX=128

sm_secrets_dev() {
	if [ -n "${SOLARMATRIX_SECRETS_DEV:-}" ]; then
		printf '%s\n' "$SOLARMATRIX_SECRETS_DEV"
		return 0
	fi
	local n
	n="$(sed -n 's/^mtd\([0-9][0-9]*\):.*"factory-secrets"$/\1/p' \
		"${SOLARMATRIX_MTD:-/proc/mtd}" 2>/dev/null)"
	[ -n "$n" ] || return 1
	printf '/dev/mtd%s\n' "$n"
}

# Succeeds only if the whole partition reads back as 0xFF. Counting the 0xFF
# bytes of a capped read proves both at once: head never passes more than
# SM_SECRETS_SIZE bytes, so a count of exactly SM_SECRETS_SIZE also means
# nothing was short. wc prints a number, which command substitution cannot
# strip the way it strips trailing newlines from raw data.
_sm_secrets_erased() {
	local ff
	ff="$(head -c "$SM_SECRETS_SIZE" "$1" 2>/dev/null | tr -d -c '\377' | wc -c | tr -d ' ')"
	[ "$ff" = "$SM_SECRETS_SIZE" ]
}

# The header line, without its newline.
_sm_secrets_header() {
	head -c "$SM_SECRETS_HDR_MAX" "$1" 2>/dev/null | head -n 1
}

# _sm_secrets_payload DEV HEADER_LEN LEN
_sm_secrets_payload() {
	tail -c +"$(($2 + 2))" "$1" 2>/dev/null | head -c "$3"
}

# _sm_secrets_len HEADER: prints <len> if HEADER is well formed, else fails.
# Fields are cut with parameter expansion, not word splitting, so flash
# content never goes through pathname expansion. Rebuilding the header from
# the parsed fields and comparing rejects extra fields, odd whitespace and
# any header without its newline (a canonical header is far shorter than
# SM_SECRETS_HDR_MAX, so a missing newline drags other bytes into it).
_sm_secrets_len() {
	local hdr="$1" rest len sum
	rest="${hdr#"$SM_SECRETS_MAGIC" }"
	len="${rest%% *}"
	sum="${rest#* }"
	[ "$hdr" = "$SM_SECRETS_MAGIC $len $sum" ] || return 1
	# More than six digits cannot fit the partition. Rejecting them here keeps
	# overflowing values away from [ -gt ] and from head -c, which on BusyBox
	# may refuse them and output nothing: the SHA-256 of nothing would then
	# make a forged header valid.
	case "$len" in ''|*[!0-9]*|???????*) return 1 ;; esac
	case "$sum" in *[!0-9a-f]*) return 1 ;; esac
	[ "${#sum}" -eq 64 ] || return 1
	[ "$len" -ge 2 ] && [ "$len" -le $((SM_SECRETS_SIZE - SM_SECRETS_HDR_MAX)) ] || return 1
	printf '%s\n' "$len"
}

# _sm_secrets_verified DEV: prints "<header_len> <len>" of a valid image.
_sm_secrets_verified() {
	local dev="$1" hdr len n got
	hdr="$(_sm_secrets_header "$dev")"
	len="$(_sm_secrets_len "$hdr")" || return 1
	n="$(_sm_secrets_payload "$dev" "${#hdr}" "$len" | wc -c | tr -d ' ')"
	[ "$n" = "$len" ] || return 1
	got="$(_sm_secrets_payload "$dev" "${#hdr}" "$len" | sha256sum | cut -d' ' -f1)"
	[ "$got" = "${hdr##* }" ] || return 1
	printf '%s %s\n' "${#hdr}" "$len"
}

sm_secrets_state() {
	local dev="${1:-}"

	if [ -z "$dev" ] || [ -d "$dev" ] || [ ! -r "$dev" ]; then
		echo corrupt
	elif _sm_secrets_erased "$dev"; then
		echo empty
	elif _sm_secrets_verified "$dev" >/dev/null; then
		echo valid
	else
		echo corrupt
	fi
	return 0
}

sm_secrets_json() {
	local dev="${1:-}" pos
	# Only a valid image passes: missing, erased and corrupt ones all fail here.
	pos="$(_sm_secrets_verified "$dev")" || return 1
	_sm_secrets_payload "$dev" "${pos% *}" "${pos#* }"
}

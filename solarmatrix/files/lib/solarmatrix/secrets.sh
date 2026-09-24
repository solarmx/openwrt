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
#   empty    the first 16 bytes are erased: an unprovisioned unit
#   valid    magic, length and SHA-256 all check out
#   corrupt  anything else, including a missing partition. Callers fail
#            closed on it: a write cut short must never reopen the
#            provisioning key.
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
	n="$(sed -n 's/^mtd\([0-9][0-9]*\):.*"factory-secrets"$/\1/p' /proc/mtd 2>/dev/null)"
	[ -n "$n" ] || return 1
	printf '/dev/mtd%s\n' "$n"
}

# The header line, without its newline.
_sm_secrets_header() {
	head -c "$SM_SECRETS_HDR_MAX" "$1" | head -n 1
}

# _sm_secrets_payload DEV HEADER_LEN LEN
_sm_secrets_payload() {
	tail -c +"$(($2 + 2))" "$1" | head -c "$3"
}

sm_secrets_state() {
	local dev="$1" hdr magic len sum extra erased got

	[ -r "$dev" ] || { echo corrupt; return 0; }

	erased=$(head -c 16 "$dev" | tr -d '\377' | wc -c)
	if [ $((erased)) -eq 0 ]; then
		echo empty
		return 0
	fi

	hdr="$(_sm_secrets_header "$dev")"
	# shellcheck disable=SC2086  # splitting the header into fields is the point
	set -- $hdr
	magic="${1:-}" len="${2:-}" sum="${3:-}" extra="${4:-}"

	# More than six digits cannot fit the partition; rejecting them here keeps
	# the numeric tests below from ever seeing a value that overflows.
	case "$len" in ''|*[!0-9]*|???????*) echo corrupt; return 0 ;; esac
	case "$sum" in ''|*[!0-9a-f]*) echo corrupt; return 0 ;; esac
	if [ "$magic" != "$SM_SECRETS_MAGIC" ] || [ -n "$extra" ] || [ "${#sum}" -ne 64 ] ||
	   [ "$len" -lt 2 ] || [ "$len" -gt $((SM_SECRETS_SIZE - SM_SECRETS_HDR_MAX)) ]; then
		echo corrupt
		return 0
	fi

	got="$(_sm_secrets_payload "$dev" "${#hdr}" "$len" | sha256sum | cut -d' ' -f1)"
	if [ "$got" = "$sum" ]; then echo valid; else echo corrupt; fi
}

sm_secrets_json() {
	local dev="$1" hdr
	[ "$(sm_secrets_state "$dev")" = valid ] || return 1
	hdr="$(_sm_secrets_header "$dev")"
	# shellcheck disable=SC2086
	set -- $hdr
	_sm_secrets_payload "$dev" "${#hdr}" "$2"
}

# SPDX-License-Identifier: GPL-2.0-or-later
#
# Opens and mounts the SolarMatrix NVMe partition, fail-closed.
#
#   secrets   partition     action
#   valid     crypto_LUKS   open with nvme_key as /dev/mapper/solarmatrix, mount ext4
#   valid     other         refuse (daemon.crit): a swapped plain drive is not trusted
#   empty     ext4          mount plain: unprovisioned, or a pilot unit from before
#                           encryption that has no factory-secrets
#   empty     other         refuse (daemon.warn): no key to open anything
#   corrupt   any           refuse (daemon.crit)
#
# The key goes to jsonfilter and cryptsetup on stdin only, never in argv
# (visible in ps), and is never logged or printed.
#
# The mount carries no noexec: the watchdog and controller still run from
# the NVMe.

. "${SOLARMATRIX_LIB:-/lib/solarmatrix}/secrets.sh"

SM_MAPPER_NAME=solarmatrix
SM_MAPPER_DIR="${SOLARMATRIX_MAPPER_DIR:-/dev/mapper}"
SM_MOUNTS="${SOLARMATRIX_MOUNTS:-/proc/mounts}"
# Init start and hotplug add can both fire for the same partition at boot.
SM_LOCK="${SOLARMATRIX_LOCK:-/var/lock/solarmatrix-storage}"
# Seconds to wait for the lock. A caller killed inside the section leaves it
# held; giving up then fails closed instead of hanging every later mount,
# shutdown included.
SM_LOCK_TRIES="${SOLARMATRIX_LOCK_TRIES:-30}"

sm_storage_log() {
	logger -t solarmatrix-storage -p "daemon.$1" "$2"
}

# Prints the source mounted at MOUNT_POINT, or nothing.
_sm_storage_source() {
	awk -v mp="$1" '$2 == mp { print $1; exit }' "$SM_MOUNTS" 2>/dev/null
}

_sm_storage_mounted() {
	[ -n "$(_sm_storage_source "$1")" ]
}

# _sm_storage_locked FUNCTION ARGS...: runs FUNCTION under the BusyBox lock.
# lock -n fails at once while someone else holds it, so the wait is bounded.
_sm_storage_locked() {
	local rc tries=1
	mkdir -p "${SM_LOCK%/*}"
	until lock -n "$SM_LOCK" 2>/dev/null; do
		if [ "$tries" -ge "$SM_LOCK_TRIES" ]; then
			sm_storage_log crit "$SM_LOCK still held after $SM_LOCK_TRIES tries; giving up"
			return 1
		fi
		tries=$((tries + 1))
		sleep 1
	done
	rc=0
	"$@" || rc=$?
	lock -u "$SM_LOCK"
	return "$rc"
}

# Prints the nvme_key of a valid image, or fails if it is missing or not
# exactly 64 lowercase hex characters. The checks on the value are the gate:
# jsonfilter's own status says nothing about what it printed. The set is
# spelled out because bracket ranges follow the caller's locale collation.
_sm_storage_key() {
	local key
	key="$(sm_secrets_json "$1" | jsonfilter -e '@.nvme_key' 2>/dev/null)"
	case "$key" in ''|*[!0123456789abcdef]*) return 1 ;; esac
	[ "${#key}" -eq 64 ] || return 1
	printf '%s' "$key"
}

# Opens DEVICE as the mapper with KEY. A mapper this call did not open may
# have been opened with some other key, so it is closed and reopened, never
# trusted.
_sm_storage_open() {
	local device="$1" key="$2"
	if [ -e "$SM_MAPPER_DIR/$SM_MAPPER_NAME" ] && ! cryptsetup close "$SM_MAPPER_NAME"; then
		sm_storage_log crit "could not close a stale $SM_MAPPER_DIR/$SM_MAPPER_NAME; not mounting $device"
		return 1
	fi
	if ! printf '%s' "$key" | cryptsetup open --type luks2 --key-file=- "$device" "$SM_MAPPER_NAME"; then
		sm_storage_log crit "could not open the encrypted volume on $device"
		return 1
	fi
}

_sm_storage_mount() {
	local device="$1" mp="$2" dev state type key src mapper="$SM_MAPPER_DIR/$SM_MAPPER_NAME"

	dev="$(sm_secrets_dev)" || dev=''
	state="$(sm_secrets_state "$dev")"

	src="$(_sm_storage_source "$mp")"
	if [ -n "$src" ]; then
		# A provisioned unit trusts only its own encrypted volume there.
		if [ "$state" = valid ] && [ "$src" != "$mapper" ]; then
			sm_storage_log crit "$mp is already mounted from $src, not $mapper"
			return 1
		fi
		return 0
	fi

	type="$(blkid -s TYPE -o value "$device" 2>/dev/null)"

	case "$state:$type" in
	valid:crypto_LUKS)
		if ! key="$(_sm_storage_key "$dev")"; then
			sm_storage_log crit "factory-secrets has no usable nvme_key; not mounting $device"
			return 1
		fi
		_sm_storage_open "$device" "$key" || return 1
		mkdir -p "$mp" && mount -t ext4 "$mapper" "$mp" || {
			sm_storage_log crit "could not mount $mapper at $mp"
			cryptsetup close "$SM_MAPPER_NAME"
			return 1
		}
		;;
	valid:*)
		sm_storage_log crit "$device is '${type:-unknown}', not LUKS; a provisioned unit mounts only its encrypted volume"
		return 1
		;;
	empty:ext4)
		mkdir -p "$mp" && mount -t ext4 "$device" "$mp" || {
			sm_storage_log crit "could not mount $device at $mp"
			return 1
		}
		;;
	empty:*)
		sm_storage_log warn "unprovisioned and $device is '${type:-unknown}'; nothing to mount"
		return 1
		;;
	*)
		sm_storage_log crit "factory-secrets is corrupt or missing; not mounting $device"
		return 1
		;;
	esac

	mkdir -p "$mp/config" "$mp/data" "$mp/logs"
	sm_storage_log info "mounted $device at $mp (secrets $state)"
	return 0
}

_sm_storage_umount() {
	local mp="$1"
	if _sm_storage_mounted "$mp" && ! umount "$mp"; then
		# Still in use: closing the mapper under a live mount would fail anyway.
		sm_storage_log crit "could not unmount $mp"
		return 1
	fi
	if [ -e "$SM_MAPPER_DIR/$SM_MAPPER_NAME" ] && ! cryptsetup close "$SM_MAPPER_NAME"; then
		sm_storage_log crit "could not close $SM_MAPPER_DIR/$SM_MAPPER_NAME"
		return 1
	fi
	return 0
}

# sm_storage_mount DEVICE MOUNT_POINT: 0 when mounted, 1 when refused.
sm_storage_mount() {
	_sm_storage_locked _sm_storage_mount "$@"
}

# sm_storage_umount MOUNT_POINT: unmounts MOUNT_POINT and closes the mapper.
# 0 when both succeeded or there was nothing to do; 1 (logged at crit) when
# either failed. A failed unmount leaves the mapper open.
sm_storage_umount() {
	_sm_storage_locked _sm_storage_umount "$@"
}

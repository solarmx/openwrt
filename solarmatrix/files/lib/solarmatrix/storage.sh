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

sm_storage_log() {
	logger -t solarmatrix-storage -p "daemon.$1" "$2"
}

_sm_storage_mounted() {
	cut -d' ' -f2 "$SM_MOUNTS" 2>/dev/null | grep -qxF "$1"
}

# _sm_storage_locked FUNCTION ARGS...: runs FUNCTION under the BusyBox lock.
_sm_storage_locked() {
	local rc
	mkdir -p "${SM_LOCK%/*}"
	if ! lock "$SM_LOCK"; then
		sm_storage_log crit "could not take $SM_LOCK"
		return 1
	fi
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
	local device="$1" mp="$2" dev state type key mapper="$SM_MAPPER_DIR/$SM_MAPPER_NAME"

	_sm_storage_mounted "$mp" && return 0

	dev="$(sm_secrets_dev)" || dev=''
	state="$(sm_secrets_state "$dev")"
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
	_sm_storage_mounted "$mp" && umount "$mp"
	[ -e "$SM_MAPPER_DIR/$SM_MAPPER_NAME" ] && cryptsetup close "$SM_MAPPER_NAME"
	return 0
}

# sm_storage_mount DEVICE MOUNT_POINT: 0 when mounted, 1 when refused.
sm_storage_mount() {
	_sm_storage_locked _sm_storage_mount "$@"
}

# sm_storage_umount MOUNT_POINT
sm_storage_umount() {
	_sm_storage_locked _sm_storage_umount "$@"
}

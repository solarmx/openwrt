# SolarMatrix OpenWRT Firmware

Fork of `git.openwrt.org/openwrt/openwrt.git` with SolarMatrix-specific
firmware build additions in this directory. Licensed under GPL-2.0-or-later
(see `solarmatrix/COPYING`).

## Reproducing our firmware

From a fresh clone:

```sh
git clone https://github.com/solarmx/openwrt
cd openwrt
./solarmatrix/build-firmware.sh prereqs      # one-time: install apt dependencies
./solarmatrix/build-firmware.sh              # build the pinned release (PINNED_TAG)
./solarmatrix/build-firmware.sh v25.12.5     # build a named release
./solarmatrix/build-firmware.sh latest       # build the newest stable release
```

The tag argument is optional: without one the script builds `PINNED_TAG`
(set in `build-firmware.sh`, currently `v25.12.5`), so a plain run is
reproducible from git alone. `latest` resolves to the newest stable
`vMAJOR.MINOR.PATCH` tag present in your clone, excluding release
candidates; it is resolved once, up front, so the checkout, the release
version (`CONFIG_VERSION_NUMBER`, shown as `DISTRIB_RELEASE`), the image
names, `tag.txt` and the license manifest all record the concrete tag that
was built. Fetch upstream tags first if the fork is behind:

```sh
git fetch upstream --tags     # or use GitHub's "Sync fork" button
```

The script:

1. Resolves the tag argument, and refuses anything that is not a real
   `refs/tags/` entry so a branch name or commit SHA cannot masquerade as
   a release.
2. Checks out that tag in detached mode.
3. Overlays `solarmatrix/` back onto the tag's tree so these build scripts
   remain available.
4. Stages `solarmatrix/files/` as the top-level `files/` rootfs overlay, which
   OpenWRT copies verbatim into the image (see [Device hardening](#device-hardening)).
5. Patches the OpenWRT One DTS (`mt7981b-openwrt-one.dts`) with
   `openwrt-one-dts.py`. The file is restored from the tag first, so a rerun
   never patches it twice; the result is written only if every check passes,
   otherwise the build fails naming each problem and the DTS is left
   untouched; and the exit trap restores it from the tag again, on success
   and on failure, so the next run's tag checkout is not blocked. The edits:
   - expose the mikroBUS SPI bus as `/dev/spidev2.0` for the MCP2515 CAN
     module (UART2 disabled, `mikrobus-reset` gpio-export dropped);
   - split the NOR `factory` partition. `factory` shrinks to
     `<0x40000 0xa0000>` and keeps the MACs and WiFi calibration read-only. A
     new writable `factory-secrets` partition, `<0xe0000 0x20000>` (128 KiB),
     sits before `fip-nor` and holds the per-device secrets the provisioning
     tool writes.

   The NOR partition table is then checked as a whole. The NOR is the one
   enabled child of `&spi2` at chip select 0 (`reg = <0>`), whatever it is
   called; no other child of `&spi2` may have a `partitions` node. The
   `partitions` node must be `compatible = "fixed-partitions"` and factory's
   `nvmem-layout` `"fixed-layout"`, since another parser would read the
   children its own way. Every child of the `partitions` node counts,
   whatever it is called, since the kernel makes an MTD partition of any
   child with a `reg`. The table
   must be exactly `bl2-nor` `0x0+0x40000`, `factory` `0x40000+0xa0000`,
   `factory-secrets` `0xe0000+0x20000`, `fip-nor` `0x100000+0x80000` and
   `recovery` `0x180000+0xc80000`: contiguous, with no gap, overlap,
   duplicate or unknown child, and no child without a `reg`. `factory` must
   be read-only with its `eeprom@0`, `macaddr@4` and `macaddr@24` nvmem cells
   inside it; `factory-secrets` must not be read-only. In the source,
   `/delete-property/` or `/delete-node/` inside `&spi2`, any `&{/path}`
   reference, and any override of a label defined in `&spi2` are refused
   too. The same table rules run again on the compiled DTB after the build
   (step 9).
6. Writes a hardcoded `.config` for **OpenWRT One** (MediaTek MT7981B,
   filogic subtarget, device `openwrt_one`), with `cryptsetup`, `kmod-dm` and
   `kmod-crypto-xts` for the LUKS2 NVMe, `odhcpd` deselected (the LAN is IPv4
   only), and failsafe compiled out (`CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE`).
   After `make defconfig` it fails the build if any requested package, the
   release version or the failsafe option was dropped, if `odhcpd` is still
   selected, if `CONFIG_TARGET_PER_DEVICE_ROOTFS` is set (the device profile,
   not this `.config`, would decide the image contents), or if `kmod-mtd-rw`
   (which makes every MTD partition writable) is selected.
7. Runs `make -j<nproc>` to produce firmware.
8. Verifies every file under `solarmatrix/files/` reached the rootfs **byte
   for byte**: the boot, hotplug, init and `solarmatrix-storage` scripts must
   also be executable; the sourced libraries, `provisioning.pub`,
   `security-model`, `inittab`, `config/dropbear` and the two no-op
   uci-defaults (`50-dropbear`, `50-root-passwd`) are compared only; for the
   files a package also ships, this proves the overlay replaced the package's
   copy. Any entry under `solarmatrix/files/` (symlinks included) that neither
   list in `build-gates.sh` covers fails the build before `make`. Stale copies
   from a previous build are deleted before `make`, so only a real overlay
   application can satisfy the check. There must be exactly one rootfs
   staging directory (`build_dir/target-*/root-mediatek*`).
9. Verifies U-Boot has no unsigned recovery paths (see the 900 patch), then
   checks the staged rootfs and images: failsafe disabled in
   `lib/preinit/00_preinit.conf`, no `login.sh` in `etc/inittab`, no
   `usr/sbin/odhcpd` (not even a symlink), no obsolete
   `sbin/solarmatrix-harden-ssh`, `etc/config/dropbear` shipped with
   `enable '0'`; this release's
   `openwrt-<version>-mediatek-filogic-openwrt_one-initramfs.itb` present and
   no larger than the 13,107,200-byte NOR `recovery` partition; and the NOR
   table of the one compiled `image-mt7981b-openwrt-one.dtb`, decompiled with
   `dtc`, passing the same rules as in step 5. In the DTB the NOR is found
   by path, not by its `compatible` (a flash bound by part name needs no
   `jedec,spi-nor`) and not through `__symbols__` (which the source can
   write). The controller is spi2 = `spi@11009000` (`mt7981b.dtsi` as
   completed by `patches-6.12/117-complete-mt7981b-dtsi.patch`; spi0 =
   `spi@1100a000` carries the NAND, spi1 = `spi@1100b000` the mikroBUS
   spidev): there must be exactly one `spi@11009000` node in the tree, at
   `/soc/spi@11009000`, with `reg` starting at `0x11009000`, and if
   `__symbols__/spi2` exists it must name that path. The controller must
   have exactly one CS0 child, whatever its status, and it and the
   controller must be enabled (by the first string of `status`, as the
   kernel reads it); no other child of the controller may have any child
   node. The only partition tables allowed anywhere (any `fixed-partitions`
   node or any node named `partitions`) are that flash's and the NAND's on
   spi0's CS0 flash, and no flash on any SPI controller may have direct
   children with a `reg` and no `compatible`, which ofpart would read as a
   legacy partition table.
10. Empties `solarmatrix/out/` and generates
    `solarmatrix/out/openwrt-licenses.json` listing every installed package's
    OSS license (per the build manifest).
11. Copies this release's firmware images (`openwrt-<version>-mediatek-filogic-*`)
    and `profiles.json` to `solarmatrix/out/`, failing on any copy that does
    not succeed, and writes `solarmatrix/out/sha256sums` over exactly the
    staged images, so `sha256sum -c sha256sums` passes in `out/`. Images of
    older releases left in `bin/targets` are not staged, and OpenWrt's own
    `sha256sums` (which covers the whole target directory, packages
    included) is not copied.

Both `version` and `files/` are generated at build time and removed again by
the script's exit trap; it refuses to start if either already exists.

Hardware target is fixed to OpenWRT One; adding other targets would
require changing the hardcoded `.config` in `build-firmware.sh`.

## Device hardening

`solarmatrix/files/` is copied verbatim into the rootfs. The access policy is
set by one boot script, with static files as a second layer:

| File | What it does |
|------|--------------|
| `etc/uci-defaults/99-solarmatrix-hardening` | Runs on every boot that follows a configuration wipe (after a flash, `firstboot` or a 5-second reset-button press), and on every boot of the NOR recovery system, which is an initramfs. Sets the posture below from the `factory-secrets` state (see [Factory secrets](#factory-secrets)). |
| `etc/config/dropbear` | Shipped closed: `enable '0'`, password and root-password auth `off`, `DirectInterface 'lan'`, port 22. If the boot script never runs, SSH stays off. |
| `etc/uci-defaults/50-dropbear` | A no-op that replaces the dropbear package's script of the same name. That one appends `board.json`'s `ssh_authorized_keys` to an empty `authorized_keys`, which it is on every first boot and every NOR recovery boot; SSH keys here come only from `99-solarmatrix-hardening`. |
| `etc/uci-defaults/50-root-passwd` | A no-op that replaces base-files' script of the same name, which sets root's password from `board.json`'s `credentials.root_password_hash` or `root_password_plain`. Root never has a usable password here. |
| `etc/inittab` | The stock file without its `askconsole` line, so the serial console offers no login. |
| `etc/solarmatrix/provisioning.pub` | Public half of the provisioning key. The private half stays on the provisioning host and is never committed. |
| `etc/security-model` | The note on what the device is, and is not, hardened against. |

The posture, applied before dropbear (`START=19`) binds a socket:

| Boot medium | `factory-secrets` | SSH |
|---|---|---|
| NAND | any | dropbear disabled, `authorized_keys` empty |
| NOR | `empty` | key-only on `lan`; `authorized_keys` = the provisioning key |
| NOR | `valid` | key-only on `lan`; `authorized_keys` = the payload's `ssh_keys` |
| NOR | `corrupt`, or `valid` with no keys or JSON that does not parse | key-only on `lan`, `authorized_keys` empty, logged at `daemon.crit` |

On NOR, dropbear is enabled only after the key-only settings have verifiably
taken; otherwise it stays disabled. An unprovisioned unit whose image lacks
`provisioning.pub` gets an empty `authorized_keys`, logged at `daemon.crit`.

The script tells NOR from NAND by the last `/` entry in `/proc/mounts`: `rootfs`
or `tmpfs` means an initramfs, anything else counts as NAND, so a wrong guess
disables SSH rather than enabling it. The initramfs is normally the NOR recovery
system, but it is also the NAND `recovery` UBI volume if U-Boot falls back to
it; both accept the same keys. It never falls back to the provisioning
key once `factory-secrets` holds anything.

On every boot, root's password field in `/etc/shadow` is set to `*`, which matches
no password (the other lines are untouched, and the temp file is created
`0600`), and `system.@system[0].ttylogin=1` is set. `uhttpd` is disabled if
present, because it binds `0.0.0.0` and cannot be restricted to the LAN.

WiFi: with a `valid` state, every `wifi-iface` gets the payload's `ssid` and
`key`, `encryption=psk2` and `disabled=0`, provided the SSID is 1–32 bytes with
no control characters and the key is 8–63 printable ASCII characters or exactly
64 hex digits. Otherwise every AP is set to `disabled=1`, and a rejected value
is logged at `daemon.crit`.

Secrets never reach argv, where `ps` would show them: the JSON reaches
`jsonfilter` on stdin, and each UCI value reaches `uci batch` on stdin. Values
are never logged, only the names of the settings.

Each concern is independent and reads its result back. Anything that did not
take is logged at `daemon.crit` and makes the script exit non-zero, which leaves
it in place to run again on the next boot.

## Factory secrets

`lib/solarmatrix/secrets.sh` (installed as `/lib/solarmatrix/secrets.sh`) is a
sourced shell library that reads the `factory-secrets` NOR partition added by
the DTS patch. The provisioning tool writes it once per unit in this format:

```
SMFS1 <len> <sha256-hex>\n     ASCII header, at most 128 bytes
<len bytes of JSON>            payload
0xFF ...                       erased remainder of the 128 KiB
```

| Function | Result |
|---|---|
| `sm_secrets_dev` | Prints the partition's `/dev/mtdN`, found by label in `/proc/mtd`; fails if there is none. |
| `sm_secrets_state DEV` | Prints `empty`, `valid` or `corrupt`. |
| `sm_secrets_json DEV` | Prints the JSON payload of a `valid` image and fails for any other state. Its output is secret; do not log it. |

- **empty**: all 131072 bytes read back and every one is `0xFF` — an
  unprovisioned unit. A short read or a partly erased partition is not empty.
- **valid**: the header is exactly `SMFS1 <len> <sha256>`, all `<len>` payload
  bytes read back, and their SHA-256 matches.
- **corrupt**: anything else, including a missing or unreadable partition.
  Callers must fail closed on it; a write cut short must never look
  unprovisioned.

For tests, `SOLARMATRIX_SECRETS_DEV` overrides the device `sm_secrets_dev`
returns and `SOLARMATRIX_MTD` replaces `/proc/mtd`.

## NVMe storage

The NVMe partition `/dev/nvme0n1p1` is mounted at `/solarmatrix` by
`/etc/init.d/solarmatrix-mount` at boot (`START=20`, after dropbear), and by
`/etc/hotplug.d/block/20-solarmatrix-nvme` when the drive appears later; the
hotplug script unmounts it again on removal. Both, and the CLI below, only call
`lib/solarmatrix/storage.sh` (`/lib/solarmatrix/storage.sh`), which decides
from the `factory-secrets` state (see [Factory secrets](#factory-secrets)) and
the partition type `blkid` reports:

| `factory-secrets` | Partition | Result |
|---|---|---|
| `valid` | `crypto_LUKS` | Opened with the payload's `nvme_key` as `/dev/mapper/solarmatrix`, which is mounted as ext4 |
| `valid` | anything else | Refused, logged at `daemon.crit`: a provisioned unit mounts only its encrypted volume |
| `empty` | `ext4` | Mounted plain: an unprovisioned unit, or a pilot unit from before encryption |
| `empty` | anything else | Refused, logged at `daemon.warn`: there is no key to open it |
| `corrupt` | any | Refused, logged at `daemon.crit` |

The rule is fail-closed: anything not in the two mounting rows leaves
`/solarmatrix` unmounted. An `nvme_key` that is missing or not exactly 64
lowercase hex characters is refused too. The key reaches `cryptsetup` on stdin
only and is never logged.

If `/solarmatrix` is already mounted, an unprovisioned unit accepts it as is. A
provisioned unit accepts it only when the visible mount is
`/dev/mapper/solarmatrix`, and a corrupt state never accepts it. A
`/dev/mapper/solarmatrix` left over from earlier is closed and reopened with
the current key, never reused, and the mapper is closed again if the mount
fails. After a successful mount, `config/`, `data/` and `logs/` are created
under `/solarmatrix`.

Calls are serialized by a lock, since the init script and hotplug can fire
together at boot. A caller that cannot get it within 30 seconds gives up and
does not mount. Unmounting also closes the mapper; a failed unmount or close is
logged at `daemon.crit` and returns non-zero (a failed unmount leaves the
mapper open).

The mount is not `noexec`: the controller binaries still run from the NVMe.

### `solarmatrix-storage`

`/usr/sbin/solarmatrix-storage` applies the same rules by hand:

| Command | What it does |
|---|---|
| `status` | Whether `/solarmatrix` is mounted, from which device, and its usage |
| `list` | NVMe block devices with their `blkid` type and size; never mounts |
| `info` | `status` and `list` |
| `mount` | Mounts via `storage.sh`, as at boot |
| `umount` | Unmounts and closes the encrypted volume |
| `remount` | `umount`, then `mount` |

A refused or failed `mount`/`umount` prints only a pointer to the log; the
reason, like everything the library logs, is in the system log under the tag
`solarmatrix-storage`:

```sh
logread -e solarmatrix-storage
```

## Tests

The scripts in this directory are covered by shell test suites, run directly:

```sh
./solarmatrix/collect-licenses_test.sh
./solarmatrix/hardening_test.sh
bash solarmatrix/secrets_test.sh
bash solarmatrix/storage_test.sh
bash solarmatrix/dts_test.sh
bash solarmatrix/build-gates_test.sh
```

`hardening_test.sh` runs the boot script against fake `uci`, `service`, `logger`
and `jsonfilter` on `PATH`, a fake `factory-secrets` image and a fake
`/proc/mounts`, and asserts on the resulting UCI state, `authorized_keys`,
shadow file, log and recorded argv, so it needs no device.
`secrets_test.sh` builds partition images in a temp directory and checks
`secrets.sh` classifies each one correctly, so it needs no device either.
`storage_test.sh` runs `storage.sh`, the `solarmatrix-mount` init script, the
hotplug script and the `solarmatrix-storage` CLI against fake `blkid`,
`cryptsetup`, `mount`, `umount`, `lock` and `logger`, a fake `factory-secrets`
image and a fake `/proc/mounts`. The library's inputs are overridable for this:
`SOLARMATRIX_LIB` (library directory), `SOLARMATRIX_MOUNTS` (`/proc/mounts`),
`SOLARMATRIX_MAPPER_DIR` (`/dev/mapper`), `SOLARMATRIX_MOUNT_POINT`
(`/solarmatrix`), `SOLARMATRIX_LOCK` and `SOLARMATRIX_LOCK_TRIES`, alongside
`SOLARMATRIX_SECRETS_DEV`.
`dts_test.sh` runs `openwrt-one-dts.py` against copies of the fork's and the
pinned release's DTS: a clean patch, a refused second patch, and one broken
NOR table per rule, in the source and, compiled with `dtc` (which it needs),
in a DTB. `build-gates_test.sh` runs each gate in `build-gates.sh` against a
fake `.config`, `build_dir` and `bin/targets`, so no build is needed.
Shared assertions and image builders live in `testlib.sh`.

## Outputs

All in `solarmatrix/out/`:

- `openwrt-<version>-mediatek-filogic-openwrt_one-factory.ubi` — factory flash image
- `openwrt-<version>-mediatek-filogic-openwrt_one-squashfs-sysupgrade.itb` — sysupgrade
- `openwrt-<version>-mediatek-filogic-openwrt_one-snand-factory.bin` — SPI NAND factory
- `openwrt-<version>-mediatek-filogic-openwrt_one-nor-factory.bin` — NOR flash factory
- `openwrt-<version>-mediatek-filogic-openwrt_one-initramfs.itb` — NOR recovery system
- plus pre-loaders, FIP bundles, manifest and profiles.json
- `sha256sums` — checksums of the staged images only (`sha256sum -c sha256sums`)
- `openwrt-licenses.json` — license notices for all installed packages
- `tag.txt` — the OpenWRT version built

## License

GPL-2.0-or-later — see `solarmatrix/COPYING`.

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
2. Checks out that tag in detached mode, then overlays `solarmatrix/` from
   the invoking branch so these build scripts remain available. It refuses
   to run from a detached HEAD.
3. Stages `solarmatrix/files/` as the top-level `files/` rootfs overlay, which
   OpenWRT copies verbatim into the image (see [Device hardening](#device-hardening)),
   and `solarmatrix/patches/uboot-mediatek/*.patch` into U-Boot's patch
   directory. Copies of overlay files that a previous build left in
   `build_dir` are deleted, so only this build's overlay can pass the
   rootfs check.
4. Updates and installs the package feeds.
5. Patches the OpenWRT One DTS (`target/linux/mediatek/dts/mt7981b-openwrt-one.dts`)
   with `openwrt-one-dts.py patch`:
   - expose the mikroBUS SPI bus as `/dev/spidev2.0` for the MCP2515 CAN
     module (UART2 disabled, `mikrobus-reset` gpio-export dropped);
   - split the NOR `factory` partition. `factory` shrinks to
     `<0x40000 0xa0000>` and keeps the MACs and WiFi calibration read-only. A
     new writable `factory-secrets` partition, `<0xe0000 0x20000>` (128 KiB),
     sits before `fip-nor` and holds the per-device secrets the provisioning
     tool writes.

   The file is restored from the tag first, so a rerun never patches it
   twice. The result is written only if every edit applied and the source
   NOR check passes (see [Build gates](#build-gates)). Otherwise the build
   fails, names each problem and leaves the DTS untouched.
6. Writes a hardcoded `.config` for **OpenWRT One** (MediaTek MT7981B,
   filogic subtarget, device `openwrt_one`), with `cryptsetup`, `kmod-dm` and
   `kmod-crypto-xts` for the LUKS2 NVMe, `odhcpd` deselected (the LAN is IPv4
   only), and failsafe compiled out (`CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE`),
   then runs `make defconfig`.
7. Runs `make -j<nproc>` to produce firmware.
8. Runs the post-build gates on the staged rootfs, U-Boot, the images and the
   compiled DTB (see [Build gates](#build-gates)).
9. Empties `solarmatrix/out/`, writes `openwrt-licenses.json` listing every
   installed package's OSS license (per the build manifest), stages this
   release's images and `profiles.json`, and writes `sha256sums` and
   `tag.txt` (see [Outputs](#outputs)).

The script refuses to start if a top-level `version` or `files` already
exists, so its exit trap never deletes anything it did not create. The trap
runs on success and on failure. It removes `files/` and the staged U-Boot
patches, and it restores the DTS from the tag so the next run's tag checkout
is not blocked. Ctrl-C or `TERM` stops the build, and the trap still runs.

Hardware target is fixed to OpenWRT One; adding other targets would
require changing the hardcoded `.config` in `build-firmware.sh`.

## Build gates

Each gate stops the build with an `ERROR:` line that names what is wrong. The
shell gates are in `build-gates.sh`, the DTS checks in `openwrt-one-dts.py`
and the U-Boot check in `build-firmware.sh`. In build order:

- **Overlay list** (before `make`): refuses any entry under
  `solarmatrix/files/`, symlinks included, that is not in
  `build-gates.sh`'s `OVERLAY_EXECUTABLES` or `OVERLAY_DATA`, so no file
  ships without the rootfs check.
- **DTS source** (before `make`): refuses a patch edit that did not apply
  (the upstream DTS changed shape) and a NOR table that breaks the
  [NOR table rules](#nor-table-rules). It also refuses `/delete-property/`
  or `/delete-node/` inside `&spi2`, any `&{/path}` reference, and any
  `&label { ... }` override of a label defined in `&spi2`.
- **defconfig** (after `make defconfig`): refuses a dropped required package
  (the `REQUIRED_PACKAGES` in `build-gates.sh`) or a dropped
  `CONFIG_VERSION_NUMBER` (the image would be built as SNAPSHOT). It also
  refuses a dropped `CONFIG_TARGET_PREINIT_DISABLE_FAILSAFE`, any selected
  `odhcpd` package and `CONFIG_TARGET_PER_DEVICE_ROOTFS` (the device
  profile, not this `.config`, would decide the image contents). Finally it
  refuses `kmod-mtd-rw` as `y` or `m`, since that makes every MTD partition
  writable, `factory` included.
- **Release version**: refuses a build that has anything other than exactly
  one rootfs staging directory (`build_dir/target-*/root-mediatek*`). It
  also refuses an `etc/openwrt_release` there without
  `DISTRIB_RELEASE='<version>'`.
- **Overlay in rootfs**: refuses any listed file that differs from
  `solarmatrix/files/` by even a byte, and any listed executable (the boot,
  hotplug, init and `solarmatrix-storage` scripts) that has lost its x bit.
  Some files are also shipped by a package: `inittab`, `config/dropbear`
  and the no-op `50-dropbear` and `50-root-passwd`. For those, the match
  proves that the overlay replaced the package's copy.
- **U-Boot**: refuses a missing NOR or SNAND `u-boot.bin`, one that still
  runs the button recovery checks (`bootcmd=run check_button`), and one
  that lacks the boot commands the 900 patch sets.
- **Rootfs**: refuses these:
  - failsafe not disabled in `lib/preinit/00_preinit.conf`;
  - `login.sh` in `etc/inittab`;
  - `usr/sbin/odhcpd` or the obsolete `sbin/solarmatrix-harden-ssh`, even
    as a dangling symlink;
  - an `etc/config/dropbear` without `option enable '0'`.
- **Initramfs**: refuses a missing
  `openwrt-<version>-mediatek-filogic-openwrt_one-initramfs.itb`, and one
  larger than the 13,107,200-byte NOR `recovery` partition. The image is
  found by this release's exact name, so an older image left in
  `bin/targets` never counts.
- **Compiled DTB**: refuses anything other than exactly one
  `image-mt7981b-openwrt-one.dtb` under `build_dir`. It then decompiles the
  DTB with `dtc` and refuses a table that breaks the
  [NOR table rules](#nor-table-rules) or the [DTB rules](#dtb-rules).
- **Staging**: refuses a build with no images for this version, a missing
  `profiles.json`, a copy that fails, or a `sha256sums` that cannot be
  written.

### NOR table rules

These rules are checked in the source and again in the compiled DTB. The NOR
is the controller's one child at chip select 0 (`reg = <0>`), whatever that
child is called. There must be exactly one such child whatever its status,
and both it and the controller must be enabled. No other child of the
controller may have child nodes. The flash's `partitions` node must be
`compatible = "fixed-partitions"` and factory's `nvmem-layout` must be
`"fixed-layout"`, because another parser would read the children its own
way. Every child of `partitions` counts, whatever it is called, because the
kernel makes an MTD partition of any child with a `reg`. The table must be
exactly:

| Partition | Offset | Size |
|---|---|---|
| `bl2-nor` | `0x0` | `0x40000` |
| `factory` | `0x40000` | `0xa0000` |
| `factory-secrets` | `0xe0000` | `0x20000` |
| `fip-nor` | `0x100000` | `0x80000` |
| `recovery` | `0x180000` | `0xc80000` |

The table must be contiguous, with no gap, overlap, duplicate or unknown
child. It must have no child without a parsable `reg` and no unit address
that differs from its `reg` offset. `factory` must be read-only, with its
`eeprom@0`, `macaddr@4` and `macaddr@24` nvmem cells inside it.
`factory-secrets` must not be read-only.

### DTB rules

In the DTB the NOR controller is found by path. It is not found by
`compatible`, because a flash bound by part name needs no `jedec,spi-nor`.
It is not found through `__symbols__` either, because the source can write
that node. The controller is spi2 = `spi@11009000` (`mt7981b.dtsi` as
completed by `patches-6.12/117-complete-mt7981b-dtsi.patch`). spi0 =
`spi@1100a000` carries the NAND and spi1 = `spi@1100b000` the mikroBUS
spidev. On top of the table rules, the DTB check requires the following:

- exactly one `spi@11009000` node in the tree, at `/soc/spi@11009000`, whose
  `reg` starts at `0x11009000`;
- if `__symbols__/spi2` exists, it must name that path;
- "enabled" means what the kernel's `of_device_is_available()` means: no
  `status`, or a first `status` string of `okay` or `ok`;
- the only partition tables allowed anywhere (any `fixed-partitions` node or
  any node named `partitions`) are the NOR's and the NAND's on spi0's CS0
  flash;
- no flash on any SPI controller may have direct children with a `reg` and
  no `compatible`, because ofpart would read those as a legacy partition
  table.

`openwrt-one-dts.py check-source DTS` runs the source check on an already
patched DTS without editing it. The build does not use it.

### Known limitations

- The DTB check models the kernel's partition parsing; it does not run the
  kernel. It is meant to catch an upstream or accidental change that
  alters the NOR table. A deliberate edit to our own DTS that exploits a
  gap left in that model is out of scope, because anyone who can edit the
  DTS can edit the gate too.
- The compiled-DTB check is first exercised by a full build.
  `dts_test.sh` runs it against DTBs that it compiles itself with `dtc`,
  not against the kernel build's `image-mt7981b-openwrt-one.dtb`.

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

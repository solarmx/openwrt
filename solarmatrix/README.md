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
./solarmatrix/build-firmware.sh v25.12.5     # build a named release
./solarmatrix/build-firmware.sh latest       # build the newest stable release
```

The tag argument is required. `latest` resolves to the newest stable
`vMAJOR.MINOR.PATCH` tag present in your clone, excluding release
candidates; it is resolved once, up front, so the checkout, the pinned
`version` file, `tag.txt` and the license manifest all record the concrete
tag that was built. Fetch upstream tags first if the fork is behind:

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
5. Patches the OpenWRT One DTS (`mt7981b-openwrt-one.dts`), and fails the
   build if any edit did not apply:
   - exposes the mikroBUS SPI bus as `/dev/spidev2.0` for the MCP2515 CAN
     module (UART2 disabled, `mikrobus-reset` gpio-export dropped);
   - splits the NOR `factory` partition. `factory` shrinks to
     `<0x40000 0xa0000>` and keeps the MACs and WiFi calibration read-only. A
     new writable `factory-secrets` partition, `<0xe0000 0x20000>` (128 KiB),
     sits before `fip-nor` and holds the per-device secrets the provisioning
     tool writes.
6. Writes a hardcoded `.config` for **OpenWRT One** (MediaTek MT7981B,
   filogic subtarget, device `openwrt_one`).
7. Runs `make -j<nproc>` to produce firmware.
8. Verifies both hardening scripts reached the rootfs **byte for byte** and are
   executable, and fails the build if not. Stale copies from a previous build
   are deleted before `make`, so only a real overlay application can satisfy it.
9. Generates `solarmatrix/out/openwrt-licenses.json` listing every
   installed package's OSS license (per the build manifest).
10. Copies firmware images to `solarmatrix/out/`.

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
taken; otherwise it stays disabled.

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

## Tests

The scripts in this directory are covered by shell test suites, run directly:

```sh
./solarmatrix/collect-licenses_test.sh
./solarmatrix/hardening_test.sh
bash solarmatrix/secrets_test.sh
```

`hardening_test.sh` runs the boot script against fake `uci`, `service`, `logger`
and `jsonfilter` on `PATH`, a fake `factory-secrets` image and a fake
`/proc/mounts`, and asserts on the resulting UCI state, `authorized_keys`,
shadow file, log and recorded argv, so it needs no device.
`secrets_test.sh` builds partition images in a temp directory and checks
`secrets.sh` classifies each one correctly, so it needs no device either.
Shared assertions and image builders live in `testlib.sh`.

## Outputs

All in `solarmatrix/out/`:

- `openwrt-mediatek-filogic-openwrt_one-factory.ubi` — factory flash image
- `openwrt-mediatek-filogic-openwrt_one-squashfs-sysupgrade.itb` — sysupgrade
- `openwrt-mediatek-filogic-openwrt_one-snand-factory.bin` — SPI NAND factory
- `openwrt-mediatek-filogic-openwrt_one-nor-factory.bin` — NOR flash factory
- plus pre-loaders, FIP bundles, manifest, checksums, profiles.json
- `openwrt-licenses.json` — license notices for all installed packages
- `tag.txt` — the OpenWRT version built

## License

GPL-2.0-or-later — see `solarmatrix/COPYING`.

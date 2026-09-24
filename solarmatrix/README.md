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

`solarmatrix/files/` is copied verbatim into the rootfs. It carries the two
scripts that keep root off the network:

| File | When it runs | What it does |
|------|--------------|--------------|
| `etc/uci-defaults/99-solarmatrix-hardening` | On every boot that follows a configuration wipe — after a flash, after `firstboot`, and after a 5-second reset-button press | Binds SSH to `br-lan`, disables `uhttpd`, and then decides the device's auth posture from what the NVMe holds (below). |
| `sbin/solarmatrix-harden-ssh` | From the boot script, as the provisioning tool's last step, and by hand after any recovery | Sets `PasswordAuth='off'` and `RootPasswordAuth='off'`, reads them back, and restarts dropbear. After this the device accepts no password over SSH. |

### Why the boot script reads the NVMe

`/etc/config/dropbear` and `/etc/shadow` are both **overlay** files. A five-second
press of the reset button runs `factoryreset -y` (`/etc/rc.button/reset`), which
wipes the overlay — taking the hardening *and* the root password with it. Left
alone, that would leave a provisioned device with password authentication back
on and no root password at all, and dropbear accepts the `none` method for root
with an empty hash (`600-allow-blank-root-password.patch`). In a shared
electrical room, the people who can reach that button are the threat.

The NVMe survives every such wipe, so it is the authority on what the device is:

| NVMe state | Posture applied before dropbear binds |
|---|---|
| No `config.json` | Unprovisioned. Root left open so the provisioning tool can reach it; both WiFi APs forced down so that window is wired-only. |
| `config.json`, no `.provisioned` | Mid-provisioning. Root password applied from `config.json`; password auth stays on, because the provisioning run needs it over the LAN. |
| `config.json` + `.provisioned` | A live unit. Root password applied **and** password auth disabled. |

`.provisioned` is written by the provisioning tool over the last SSH session
there will be, immediately before it locks the device — it cannot be written
afterwards, because by then nothing can log in. The run then reconnects and
refuses to report success unless a root password is actually refused, so the
marker means "provisioning reached the end" while the run's exit status is what
says the device is fit to ship.

The script **fails closed**: if `config.json` is present but the password cannot
be applied, password authentication goes off anyway. A device that needs failsafe
to recover is recoverable; a passwordless rootable one in a shared building is
not.

Ordering makes this work: uci-defaults run from `/etc/init.d/boot` (`START=10`),
before dropbear (`START=19`) has bound a socket. The NVMe is not mounted that
early — `/etc/init.d/solarmatrix-mount` is `START=20` — so the script mounts it
read-only itself and unmounts it again.

Every concern is independent and reads its result back; anything that did not
take is logged at `daemon.crit` and makes the script exit non-zero, which leaves
it in place to run again on the next boot. It runs unattended with nobody
reading its exit code, so failing silently open is the one outcome it must not
have.

The device keeps a unique, strong root password — generated per device during
provisioning, written to `/solarmatrix/config.json`, and applied to the account.
It is simply not accepted from the network, and it is never printed. It reaches
`chpasswd` on stdin, never in argv, so it does not appear in `ps` output.

**Recovery.** With no password authentication, root is reached through OpenWRT
failsafe mode, which requires physical access. Failsafe is unaffected by any of
the above: `/lib/preinit/99_10_failsafe_dropbear` starts its own dropbear with
an explicit command line and a throwaway host key, and
`/lib/preinit/99_10_failsafe_login` opens a serial console shell — neither
reads `/etc/config/dropbear`. The full runbook lives in
[`docs/RECOVERY.md`](https://github.com/solar-matrix/provisioning/blob/main/docs/RECOVERY.md)
in the provisioning repository.

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

`hardening_test.sh` runs the hardening scripts against a fake `uci` and `service`
on `PATH` and asserts on the resulting UCI state, so it needs no device.
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

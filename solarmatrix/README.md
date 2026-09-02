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
5. Writes a hardcoded `.config` for **OpenWRT One** (MediaTek MT7981B,
   filogic subtarget, device `openwrt_one`).
6. Runs `make -j<nproc>` to produce firmware.
7. Verifies the hardening overlay actually reached the rootfs, and fails the
   build if it did not.
8. Generates `solarmatrix/out/openwrt-licenses.json` listing every
   installed package's OSS license (per the build manifest).
9. Copies firmware images to `solarmatrix/out/`.

Both `version` and `files/` are generated at build time and removed again by
the script's exit trap; it refuses to start if either already exists.

Hardware target is fixed to OpenWRT One; adding other targets would
require changing the hardcoded `.config` in `build-firmware.sh`.

## Device hardening

`solarmatrix/files/` is copied verbatim into the rootfs. It carries the two
scripts that keep root off the network:

| File | When it runs | What it does |
|------|--------------|--------------|
| `etc/uci-defaults/99-solarmatrix-hardening` | Once, at first boot after flashing | Sets `dropbear.@dropbear[0].DirectInterface='lan'` so SSH is bound to `br-lan` (wired LAN plus both WiFi APs) and never to WAN. Disables `uhttpd` if present, since it can only listen on the `0.0.0.0` wildcard and the controller owns port 80. |
| `sbin/solarmatrix-harden-ssh` | Last step of provisioning, and by hand after any recovery | Sets `PasswordAuth='off'` and `RootPasswordAuth='off'`, reads them back, and restarts dropbear. After this the device accepts no password over SSH. |

The device keeps a unique, strong root password — it is generated per device
during provisioning, written to `/solarmatrix/config.json`, and applied to the
account. It is simply not accepted from the network, and it is never printed.

Password authentication is left on at first boot on purpose: provisioning
authenticates as root over the LAN to finish setting the device up, and only
then locks it down.

**Recovery.** With no password authentication, root is reached through OpenWRT
failsafe mode, which requires physical access. Failsafe is unaffected by any of
the above: `/lib/preinit/99_10_failsafe_dropbear` starts its own dropbear with
an explicit command line and a throwaway host key, and
`/lib/preinit/99_10_failsafe_login` opens a serial console shell — neither
reads `/etc/config/dropbear`. The full runbook lives in
[`docs/RECOVERY.md`](https://github.com/solar-matrix/provisioning/blob/main/docs/RECOVERY.md)
in the provisioning repository.

## Tests

The scripts in this directory are covered by shell test suites, run directly:

```sh
./solarmatrix/collect-licenses_test.sh
./solarmatrix/hardening_test.sh
```

`hardening_test.sh` runs the hardening scripts against a fake `uci` and `service`
on `PATH` and asserts on the resulting UCI state, so it needs no device.

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

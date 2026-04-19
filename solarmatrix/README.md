# SolarMatrix OpenWRT Firmware

Fork of `git.openwrt.org/openwrt/openwrt.git` with SolarMatrix-specific firmware build additions in this directory.

## First-time setup

Run from the repo root (one time, per build machine):

```sh
./solarmatrix/build-firmware.sh prereqs      # install OpenWRT build deps (apt-get)
make menuconfig                              # pick target + options, save .config
```

`.config` is local to your checkout — it is gitignored by OpenWRT. Different build hosts can target different hardware.

## Build

```sh
./solarmatrix/build-firmware.sh
```

Syncs `upstream` → auto-picks the latest `vMAJOR.MINOR.PATCH` tag → checks it out in detached mode → runs `make defconfig` (against your saved `.config`) → `make -j<nproc>` → emits artifacts to `solarmatrix/out/`.

## Outputs

- `solarmatrix/out/*.bin` / `*.img` / `*.ipk` — firmware images
- `solarmatrix/out/openwrt-licenses.json` — OSS notices for every installed package (consumed by the controller release pipeline via the `OPENWRT_LICENSES_JSON` env var)
- `solarmatrix/out/tag.txt` — the OpenWRT version that was built

## License

This directory (and the script) is released under GPL-2.0-or-later — see `solarmatrix/COPYING`. The rest of the repo retains its upstream OpenWRT license.

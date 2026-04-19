# SolarMatrix OpenWRT Firmware

Fork of `git.openwrt.org/openwrt/openwrt.git` with SolarMatrix-specific firmware build additions in this directory.

## Build

```sh
./solarmatrix/build-firmware.sh
```

Syncs `upstream` → auto-picks the latest `vMAJOR.MINOR.PATCH` tag → checks it out in detached mode → copies `solarmatrix/config.solarmatrix` to `.config` → `make defconfig` → `make -j<nproc>` → emits artifacts to `solarmatrix/out/`.

## Outputs

- `solarmatrix/out/*.bin` / `*.img` / `*.ipk` — firmware images
- `solarmatrix/out/openwrt-licenses.json` — OSS notices for every installed package (consumed by the controller release pipeline via the `OPENWRT_LICENSES_JSON` env var)
- `solarmatrix/out/tag.txt` — the OpenWRT version that was built

## License

This directory (and the script) is released under GPL-2.0-or-later — see `solarmatrix/COPYING`. The rest of the repo retains its upstream OpenWRT license.

# SolarMatrix OpenWRT Firmware

Fork of `git.openwrt.org/openwrt/openwrt.git` with SolarMatrix-specific firmware build additions in this directory.

## First-time setup

Run from the repo root (one time, per build machine):

```sh
./solarmatrix/build-firmware.sh prereqs      # install OpenWRT build deps (apt-get)
```

## Build

```sh
./solarmatrix/build-firmware.sh
```

Syncs `upstream` → auto-picks the latest `vMAJOR.MINOR.PATCH` tag → checks it out detached → overlays `solarmatrix/` from the invoking branch → writes a hardcoded OpenWRT One (mediatek/filogic) `.config` → `make defconfig` → `make -j<nproc>` → emits artifacts to `solarmatrix/out/`.

Hardware target is fixed to **OpenWRT One** (MediaTek MT7981B, filogic subtarget). This is the only platform SolarMatrix ships on; adding more targets would require config changes to the build script.

## Outputs

- `solarmatrix/out/*.bin` / `*.img` — firmware images (sysupgrade + factory variants)
- `solarmatrix/out/openwrt-licenses.json` — OSS notices for every installed package
- `solarmatrix/out/tag.txt` — the OpenWRT version that was built

## License

GPL-2.0-or-later — see `solarmatrix/COPYING`.

# SolarMatrix OpenWRT Firmware

Fork of `git.openwrt.org/openwrt/openwrt.git` with SolarMatrix-specific
firmware build additions in this directory. Licensed under GPL-2.0-or-later
(see `solarmatrix/COPYING`).

## Reproducing our firmware

From a fresh clone:

```sh
git clone https://github.com/solarmx/openwrt
cd openwrt
./solarmatrix/build-firmware.sh prereqs    # one-time: install apt dependencies
./solarmatrix/build-firmware.sh            # build
```

The script:

1. Picks the latest stable `vMAJOR.MINOR.PATCH` tag from your local clone
   (use GitHub's "Sync fork" button to pull newer upstream tags when needed).
2. Checks out that tag in detached mode.
3. Overlays `solarmatrix/` back onto the tag's tree so these build scripts
   remain available.
4. Writes a hardcoded `.config` for **OpenWRT One** (MediaTek MT7981B,
   filogic subtarget, device `openwrt_one`).
5. Runs `make -j<nproc>` to produce firmware.
6. Generates `solarmatrix/out/openwrt-licenses.json` listing every
   installed package's OSS license (per the build manifest).
7. Copies firmware images to `solarmatrix/out/`.

Hardware target is fixed to OpenWRT One; adding other targets would
require changing the hardcoded `.config` in `build-firmware.sh`.

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

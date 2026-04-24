# solarmatrix/licenses

Checked-in license overrides for OpenWRT packages that `collect-licenses.sh`
cannot otherwise resolve (vendor firmware blobs with no SPDX id, no source,
and no LICENSE file in `$PKG_BUILD_DIR`).

## vendor-firmware/

Two files per package, same basename:

- `<pkg-name>.txt` — full redistribution terms, UTF-8, LF line endings.
- `<pkg-name>.license` — one-line vendor or SPDX identifier. `UNKNOWN` is
  not allowed here; pick a stable internal string (e.g. `Proprietary-Airoha-Firmware`).

Both files must exist or neither must exist. `collect-licenses.sh` hard
fails if only one of the pair is present. If a package has
`license=UNKNOWN` after all other resolution paths and has no override,
`collect-licenses.sh` hard fails naming the two files it expects.

Override content wins over any other source.

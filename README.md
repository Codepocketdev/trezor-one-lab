# trezor-one-lab

Experiments with custom firmware for the **Trezor Model One** (legacy firmware).
Each experiment is its own patch against upstream trezor-firmware, so they can be built separately.

| # | Experiment | Status |
|---|---|---|
| 01 | Clock and date home screen, time set over USB | working on a real device |
| 02 | Nostr event signer | planned |
| 03 | Snake | planned |

> **Warning.** This is unofficial, unsigned and unaudited firmware. Installing it **wipes any seed stored on the device**.
> Use only a spare Trezor that holds no seed and no funds. Never put real funds on a device running it.
> Trezor Suite can reinstall official firmware while the device is in bootloader mode.

## 01 - Clock: what it does
- Home screen shows large `HH:MM:SS` and a date line, no logo or URL.
- The Model One has no real-time clock: it starts from the build time and counts forward until the host sets the time.
- `SETTIME <utc_unix_seconds> [<utc_offset_seconds>]` is accepted inside a normal `Ping` message,
  so no protobuf changes are needed. It is **unauthenticated**: anyone with USB access can set the clock.
- The emulator build uses the host clock (UTC+3) until a time is sent.

## What is in this repo
- `patches/01-clock.patch` - the change, as a diff against upstream trezor-firmware commit `9d4f7db2b06fc91e2b5d64d6d6426fb0cd44a3d7`
- `scripts/apply_clock3.sh` - applies the same change by editing the source (idempotent, keeps `.orig` backups)
- `scripts/vps_setup.sh` - installs the ARM toolchain and fetches only the submodules the Model One build needs
- `scripts/settime.sh`, `scripts/settime.ps1` - send the current time to the emulator or a device

## Build (device)
```bash
git clone --depth 1 https://github.com/trezor/trezor-firmware.git && cd trezor-firmware
git fetch --depth 1 origin 9d4f7db2b06fc91e2b5d64d6d6426fb0cd44a3d7 && git checkout 9d4f7db2b06fc91e2b5d64d6d6426fb0cd44a3d7
git submodule update --init --depth 1 vendor/nanopb vendor/libopencm3 vendor/secp256k1-zkp vendor/QR-Code-generator vendor/ts-tvl
git apply /path/to/patches/01-clock.patch
cd legacy && unset EMULATOR HEADLESS DEBUG_LINK && export PRODUCTION=0
TZ=Africa/Nairobi uv run ./script/cibuild      # output: firmware/trezor.bin
```
`PRODUCTION=0` is required for unofficial firmware. Needs `gcc-arm-none-eabi`.

## Flash (Windows, with the device in bootloader mode)
```powershell
trezorctl firmware update -f trezor.bin
```
Confirm the unofficial-firmware prompt on the device. Then run `scripts/settime.ps1` after each plug-in.

## Notes
- The first build I made: firmware 1.14.4, SHA-256 `8c09f0e60bcf5cef429439de8c62e4083ee42b413b59450e659a35902976fcd3`. Builds are **not reproducible** because the build date and time are compiled in.
- Tested in the Trezor emulator and on one Model One.
- Time is kept in RAM, so unplugging loses it.

## License
LGPL-3.0, matching upstream trezor-firmware's `legacy/` directory (see `LICENSE`).
The patches and scripts here are released under the same license.

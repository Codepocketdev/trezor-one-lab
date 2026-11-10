# trezor-one-lab

Experiments with custom firmware for the **Trezor Model One** (legacy firmware).
Each experiment is its own patch against upstream trezor-firmware, so they can be built separately.

| # | Experiment | Status |
|---|---|---|
| 01 | Clock and date home screen, time set over USB | working on a real device |
| 02 | Nostr event signer (NIP-06 key, on-device review) | working on a real device, lab only |
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

## 02 - Nostr event signer (lab only)
Patch `patches/02-nostr-signer.patch` applies **on top of** 01. Commands are sent as text inside `Ping`
(the reply comes back in the Success message), so no protobuf changes are needed:

- `NOSTRPUB` returns the x-only public key for NIP-06 path `m/44'/1237'/0'/0/0`.
- `NOSTREV BEGIN <len>`, `NOSTREV ADD <offset> <text>`, `NOSTREV SIGN` send the exact NIP-01 serialization
  in chunks. The device accepts only its own pubkey, plain ASCII and canonical escapes, shows the kind, the tag
  count, **every tag as it will be hashed**, and the content page by page, and signs only after a button press on
  every page. The reply is `<event id> <signature>` (BIP-340, random aux data).
- `tools/nostr_send.py` builds the event on the PC, drives the device, and verifies the id and signature.
- `tools/nostr_ref.py` is a slow pure-Python reference (NIP-06, BIP-340) for cross-checking. Test seeds only.

Limits: ASCII only, content up to 400 characters, up to 20 tags, event up to 900 bytes. The Ping channel is
unauthenticated, so the on-device review is the only protection. The Model One has no secure element and this
firmware is unaudited: use a spare device and a throwaway seed. Tested on one Model One: a kind-1 note with a tag
was signed and the id and signature verified.

## Notes
- The first build I made: firmware 1.14.4, SHA-256 `8c09f0e60bcf5cef429439de8c62e4083ee42b413b59450e659a35902976fcd3`. Builds are **not reproducible** because the build date and time are compiled in.
- Tested in the Trezor emulator and on one Model One.
- Time is kept in RAM, so unplugging loses it.

## License
LGPL-3.0, matching upstream trezor-firmware's `legacy/` directory (see `LICENSE`).
The patches and scripts here are released under the same license.

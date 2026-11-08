#!/usr/bin/env bash
set -euo pipefail
head -2 /etc/os-release; df -h / | tail -1; free -h | sed -n 2p
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO apt update
$SUDO apt install -y --no-install-recommends git python3 curl ca-certificates \
  build-essential make gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi
arm-none-eabi-gcc --version | head -1
curl -LsSf https://astral.sh/uv/install.sh | sh
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
uv --version
cd ~
[ -d trezor-firmware ] || git clone --depth 1 https://github.com/trezor/trezor-firmware.git
cd trezor-firmware
git submodule update --init --depth 1 vendor/nanopb vendor/libopencm3 \
  vendor/secp256k1-zkp vendor/QR-Code-generator vendor/ts-tvl
echo "--- submodules fetched:"; git submodule status | grep -v '^-' || true
echo "VPS setup done"

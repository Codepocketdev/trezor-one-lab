#!/usr/bin/env bash
# apply_nostr1.sh - Trezor Model One experiment 02, step 1: NOSTRPUB.
# Adds a Ping command "NOSTRPUB" that returns the NIP-06 public key (m/44'/1237'/0'/0/0, BIP340 x-only, hex).
# Run AFTER apply_clock3.sh (re-running apply_clock3.sh removes this patch).
# Usage: ./apply_nostr1.sh [--build] [--revert] [REPO_DIR]   --build also builds the DEVICE firmware (PRODUCTION=0)
set -euo pipefail

BUILD=0
REVERT=0
REPO="$HOME/trezor-firmware"
for arg in "$@"; do
  case "$arg" in
    --build)  BUILD=1 ;;
    --revert) REVERT=1 ;;
    *) REPO="$arg" ;;
  esac
done

FW="$REPO/legacy/firmware"
FSMCOMMON="$FW/fsm_msg_common.h"
FSM="$FW/fsm.c"
BACKUP="$FSMCOMMON.pre-nostr"

[ -f "$FSMCOMMON" ] && [ -f "$FSM" ] || { echo "ERROR: cannot find $FSMCOMMON or $FSM" >&2; exit 1; }

if [ "$REVERT" -eq 1 ]; then
  [ -f "$BACKUP" ] && cp "$BACKUP" "$FSMCOMMON" && echo "restored fsm_msg_common.h from before the Nostr patch" || echo "no backup, nothing to do"
  exit 0
fi

if grep -q "nostr_pubkey_hex" "$FSMCOMMON"; then
  echo "already patched, skipping the edit"
else
  for m in CHECK_INITIALIZED CHECK_PIN; do
    grep -q "define $m" "$FSM" || { echo "ERROR: macro $m not found in fsm.c, tell Claude" >&2; exit 1; }
  done
  [ -f "$BACKUP" ] || cp "$FSMCOMMON" "$BACKUP"

  python3 - "$FSMCOMMON" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

sig = "void fsm_msgPing(const Ping *msg) {"
if src.count(sig) != 1:
    sys.exit("ERROR: expected exactly one fsm_msgPing definition")
i = src.index(sig)
anchor = "  if (msg->has_message) {\n    resp->has_message = true;"
j = src.find(anchor, i)
if j < 0:
    sys.exit("ERROR: could not find the has_message echo block inside fsm_msgPing")

HELPER = r'''#include "zkp_bip340.h"

// ---- Nostr experiment: NIP-06 key m/44'/1237'/0'/0/0, BIP340. Test seeds only. ----
static void nostr_hex(const uint8_t *data, size_t len, char *out) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < len; i++) {
    out[2 * i] = digits[data[i] >> 4];
    out[2 * i + 1] = digits[data[i] & 15];
  }
  out[2 * len] = 0;
}

// Fills out[65] with the x-only public key in hex.
// Returns 0 on success, -1 if no key node (a failure was already reported), -2 on a bad key.
static int nostr_pubkey_hex(char *out) {
  static const uint32_t path[5] = {0x80000000u | 44, 0x80000000u | 1237,
                                   0x80000000u | 0, 0, 0};
  HDNode *node = fsm_getDerivedNode("secp256k1", path, 5, NULL);
  if (!node) return -1;
  uint8_t pub[32];
  if (zkp_bip340_get_public_key(node->private_key, pub) != 0) return -2;
  nostr_hex(pub, sizeof(pub), out);
  return 0;
}

'''

COMMAND = '''  // Nostr experiment: "NOSTRPUB" returns the NIP-06 public key (hex)
  if (msg->has_message && strcmp(msg->message, "NOSTRPUB") == 0) {
    CHECK_INITIALIZED
    CHECK_PIN
    char hex[65];
    int r = nostr_pubkey_hex(hex);
    if (r == -1) return;
    if (r != 0) {
      fsm_sendFailure(FailureType_Failure_ProcessError,
                      _("Could not derive the Nostr key"));
      layoutHome();
      return;
    }
    resp->has_message = true;
    memcpy(resp->message, hex, sizeof(hex));
    msg_write(MessageType_MessageType_Success, resp);
    layoutHome();
    return;
  }

'''
src = src[:j] + COMMAND + src[j:]
src = src[:i] + HELPER + src[i:]
open(path, "w").write(src)
print("patched fsm_msg_common.h")
PYEOF
fi

git -C "$REPO" diff --stat -- legacy/firmware/fsm_msg_common.h || true

if [ "$BUILD" -eq 1 ]; then
  echo "Building device firmware..."
  export PATH="$HOME/.local/bin:$PATH"
  unset EMULATOR HEADLESS DEBUG_LINK
  export PRODUCTION=0
  touch "$FSMCOMMON" "$FSM"
  ( cd "$REPO/legacy" && TZ=Africa/Nairobi uv run ./script/cibuild )
  echo
  ls -l "$REPO/legacy/firmware/trezor.bin"
  sha256sum "$REPO/legacy/firmware/trezor.bin"
  echo "Copy firmware/trezor.bin to your PC and flash it, then:"
  echo "  trezorctl device load -m \"<test words>\"   (confirm on the device)"
  echo "  trezorctl ping NOSTRPUB"
fi

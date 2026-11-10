#!/usr/bin/env bash
# apply_nostr2.sh - Trezor Model One experiment 02, step 2: NOSTRSIGN.
# Adds a Ping command:  NOSTRSIGN <created_at> <kind> <content>
# The device builds the NIP-01 event itself, shows the text, and signs only after you press the button.
# Returns "<event id hex> <signature hex>". Content: 1-80 printable ASCII chars (so all of it fits on the OLED).
# Run AFTER apply_nostr1.sh (re-running apply_clock3.sh or apply_nostr1.sh removes this patch).
# Usage: ./apply_nostr2.sh [--build] [--revert] [REPO_DIR]   --build also builds the DEVICE firmware (PRODUCTION=0)
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
BACKUP="$FSMCOMMON.pre-nostr2"

[ -f "$FSMCOMMON" ] && [ -f "$FSM" ] || { echo "ERROR: cannot find $FSMCOMMON or $FSM" >&2; exit 1; }

if [ "$REVERT" -eq 1 ]; then
  [ -f "$BACKUP" ] && cp "$BACKUP" "$FSMCOMMON" && echo "restored fsm_msg_common.h from before the NOSTRSIGN patch" || echo "no backup, nothing to do"
  exit 0
fi

if grep -q "nostr_sign_command" "$FSMCOMMON"; then
  echo "already patched, skipping the edit"
else
  grep -q "nostr_pubkey_hex" "$FSMCOMMON" || { echo "ERROR: run apply_nostr1.sh first" >&2; exit 1; }
  [ -f "$BACKUP" ] || cp "$FSMCOMMON" "$BACKUP"

  python3 - "$FSMCOMMON" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

sigline = "void fsm_msgPing(const Ping *msg) {"
if src.count(sigline) != 1:
    sys.exit("ERROR: expected exactly one fsm_msgPing definition")
anchor = '  // Nostr experiment: "NOSTRPUB" returns the NIP-06 public key (hex)\n'
if src.count(anchor) != 1:
    sys.exit("ERROR: could not find the NOSTRPUB block, was apply_nostr1.sh applied?")

HELPER = r'''#include "rand.h"
#include "sha2.h"

// ---- Nostr experiment, step 2: NOSTRSIGN <created_at> <kind> <content> ----
// Content is 1-80 printable ASCII chars so the whole note fits on the OLED:
// what you read on the screen is exactly what gets signed.
#define NOSTR_MAX_CONTENT 80

static const char *nostr_parse_uint(const char *s, uint32_t limit,
                                    uint32_t *out) {
  uint64_t v = 0;
  const char *p = s;
  while (*p >= '0' && *p <= '9') {
    v = v * 10 + (uint64_t)(*p - '0');
    if (v > limit) return NULL;
    p++;
  }
  if (p == s) return NULL;
  *out = (uint32_t)v;
  return p;
}

static size_t nostr_utoa(uint32_t v, char *out) {
  char tmp[10];
  size_t n = 0, k = 0;
  do {
    tmp[n++] = (char)('0' + (v % 10));
    v /= 10;
  } while (v);
  while (n) out[k++] = tmp[--n];
  out[k] = 0;
  return k;
}

static HDNode *nostr_node(void) {
  static const uint32_t nostr_path[5] = {0x80000000u | 44, 0x80000000u | 1237,
                                         0x80000000u | 0, 0, 0};
  return fsm_getDerivedNode("secp256k1", nostr_path, 5, NULL);
}

// Returns 0 on success (out gets "<id hex> <sig hex>", 193 chars),
// -1 key derivation failed (failure already sent), -2 bad input,
// -3 cancelled on the device, -4 signing error.
static int nostr_sign_command(const char *args, char *out) {
  uint32_t created_at = 0, kind = 0;
  const char *p = nostr_parse_uint(args, 0xFFFFFFFFu, &created_at);
  if (!p || *p != ' ') return -2;
  p = nostr_parse_uint(p + 1, 65535u, &kind);
  if (!p || *p != ' ') return -2;
  const char *content = p + 1;
  size_t clen = strlen(content);
  if (clen == 0 || clen > NOSTR_MAX_CONTENT) return -2;
  for (size_t i = 0; i < clen; i++) {
    uint8_t c = (uint8_t)content[i];
    if (c < 0x20 || c > 0x7e) return -2;
  }

  HDNode *node = nostr_node();
  if (!node) return -1;
  uint8_t pub[32];
  if (zkp_bip340_get_public_key(node->private_key, pub) != 0) return -4;
  char pubhex[65];
  nostr_hex(pub, sizeof(pub), pubhex);

  // NIP-01 serialization: [0,"<pubkey>",<created_at>,<kind>,[],"<content>"]
  static char ser[320];
  size_t n = 0;
  memcpy(ser + n, "[0,\"", 4);
  n += 4;
  memcpy(ser + n, pubhex, 64);
  n += 64;
  memcpy(ser + n, "\",", 2);
  n += 2;
  n += nostr_utoa(created_at, ser + n);
  ser[n++] = ',';
  n += nostr_utoa(kind, ser + n);
  memcpy(ser + n, ",[],\"", 5);
  n += 5;
  for (size_t i = 0; i < clen; i++) {
    if (content[i] == '"' || content[i] == '\\') ser[n++] = '\\';
    ser[n++] = content[i];
  }
  ser[n++] = '"';
  ser[n++] = ']';
  ser[n] = 0;

  // Show the note: a title line plus the content in 4 lines of 20 chars.
  char title[24];
  size_t t = 11;
  memcpy(title, "Nostr kind ", 11);
  t += nostr_utoa(kind, title + t);
  title[t++] = ':';
  title[t] = 0;
  char lines[4][21];
  for (size_t row = 0; row < 4; row++) {
    size_t off = row * 20;
    size_t take = 0;
    if (off < clen) {
      take = clen - off;
      if (take > 20) take = 20;
      memcpy(lines[row], content + off, take);
    }
    lines[row][take] = 0;
  }
  layoutDialogSwipe(NULL, _("Cancel"), _("Sign"), NULL, title, lines[0],
                    lines[1][0] ? lines[1] : NULL,
                    lines[2][0] ? lines[2] : NULL,
                    lines[3][0] ? lines[3] : NULL, NULL);
  if (!protectButton(ButtonRequestType_ButtonRequest_ProtectCall, false)) {
    return -3;
  }

  // Fetch the key again after the dialog, then sign the event id.
  node = nostr_node();
  if (!node) return -1;
  uint8_t n_digest[32], n_sig[64], n_aux[32];
  sha256_Raw((const uint8_t *)ser, n, n_digest);
  random_buffer(n_aux, sizeof(n_aux));
  if (zkp_bip340_sign_digest(node->private_key, n_digest, n_sig, n_aux) != 0) {
    return -4;
  }
  nostr_hex(n_digest, sizeof(n_digest), out);
  out[64] = ' ';
  nostr_hex(n_sig, sizeof(n_sig), out + 65);
  return 0;
}

'''

COMMAND = r'''  // Nostr experiment: "NOSTRSIGN <created_at> <kind> <content>" signs a short note after on-device confirmation
  if (msg->has_message && strncmp(msg->message, "NOSTRSIGN ", 10) == 0) {
    CHECK_INITIALIZED
    CHECK_PIN
    int nostr_r = nostr_sign_command(msg->message + 10, resp->message);
    if (nostr_r == -1) return;
    if (nostr_r == -2) {
      fsm_sendFailure(FailureType_Failure_DataError,
                      _("Use: NOSTRSIGN time kind text (80 ASCII max)"));
      layoutHome();
      return;
    }
    if (nostr_r == -3) {
      fsm_sendFailure(FailureType_Failure_ActionCancelled, NULL);
      layoutHome();
      return;
    }
    if (nostr_r != 0) {
      fsm_sendFailure(FailureType_Failure_ProcessError,
                      _("Nostr signing failed"));
      layoutHome();
      return;
    }
    resp->has_message = true;
    msg_write(MessageType_MessageType_Success, resp);
    layoutHome();
    return;
  }

'''
a = src.index(anchor)
src = src[:a] + COMMAND + src[a:]
i = src.index(sigline)
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
  echo "  trezorctl device setup"
  echo "  trezorctl ping NOSTRPUB"
  echo "  trezorctl ping \"NOSTRSIGN <unix time> 1 hello\"   (confirm on the device)"
fi

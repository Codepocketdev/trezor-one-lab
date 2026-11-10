#!/usr/bin/env bash
# apply_nostr3.sh - Trezor Model One experiment 02, step 4: NOSTREV (full events, in chunks).
# Adds Ping commands:  NOSTREV BEGIN <len> | NOSTREV ADD <offset> <text> | NOSTREV SIGN
# The text is the exact NIP-01 event serialization. The device checks it strictly (own pubkey,
# ASCII only, canonical escapes), shows kind, tag count and the content page by page, and signs
# only after you press the button on every page. Returns "<event id hex> <signature hex>".
# The older NOSTRSIGN command stays. Run AFTER apply_nostr2.sh.
# Usage: ./apply_nostr3.sh [--build] [--revert] [REPO_DIR]   --build also builds the DEVICE firmware
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
BACKUP="$FSMCOMMON.pre-nostr3"

[ -f "$FSMCOMMON" ] && [ -f "$FSM" ] || { echo "ERROR: cannot find $FSMCOMMON or $FSM" >&2; exit 1; }

if [ "$REVERT" -eq 1 ]; then
  [ -f "$BACKUP" ] && cp "$BACKUP" "$FSMCOMMON" && echo "restored fsm_msg_common.h from before the NOSTREV patch" || echo "no backup, nothing to do"
  exit 0
fi

if grep -q "nostr_ev_command" "$FSMCOMMON"; then
  echo "already patched, skipping the edit"
else
  grep -q "nostr_sign_command" "$FSMCOMMON" || { echo "ERROR: run apply_nostr2.sh first" >&2; exit 1; }
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

HELPER = r'''// ---- Nostr experiment, step 4: full NIP-01 events, sent in chunks ----
// Host: NOSTREV BEGIN <total_len>, NOSTREV ADD <offset> <text>..., NOSTREV SIGN
// The text is the exact NIP-01 serialization that gets hashed. The device checks
// it strictly (own pubkey, ASCII only, canonical escapes, no spaces), then shows
// the content page by page exactly as it will be hashed, and signs on approval.
#define NOSTR_EV_MAX 900
#define NOSTR_CONTENT_MAX 400
#define NOSTR_TAGS_MAX 20

static char nostr_ev[NOSTR_EV_MAX + 1];
static size_t nostr_ev_len = 0;
static size_t nostr_ev_want = 0;
static const char *nostr_ev_err = "";

typedef struct {
  uint32_t kind;
  size_t tags;
  char letters[NOSTR_TAGS_MAX + 1];
  const char *content;
  size_t content_len;
} nostr_ev_info;

static void nostr_ev_reset(void) {
  memset(nostr_ev, 0, sizeof(nostr_ev));
  nostr_ev_len = 0;
  nostr_ev_want = 0;
}

static size_t nostr_ev_utoa(uint32_t v, char *out) {
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

static bool nostr_p_char(const char **pp, const char *end, char c) {
  if (*pp < end && **pp == c) {
    (*pp)++;
    return true;
  }
  return false;
}

static bool nostr_p_uint(const char **pp, const char *end, uint32_t limit,
                         uint32_t *out) {
  const char *p = *pp;
  uint64_t v = 0;
  size_t digits = 0;
  while (p < end && *p >= '0' && *p <= '9') {
    if (digits > 0 && v == 0) return false;  // no leading zeros
    v = v * 10 + (uint64_t)(*p - '0');
    if (v > limit) return false;
    digits++;
    p++;
  }
  if (digits == 0) return false;
  *pp = p;
  *out = (uint32_t)v;
  return true;
}

// A JSON string with only the NIP-01 escapes and printable ASCII.
// Returns the raw (still escaped) text between the quotes.
static bool nostr_p_string(const char **pp, const char *end, const char **start,
                           size_t *len) {
  const char *p = *pp;
  if (p >= end || *p != '"') return false;
  p++;
  const char *s = p;
  while (p < end) {
    uint8_t c = (uint8_t)*p;
    if (c == '"') {
      *start = s;
      *len = (size_t)(p - s);
      *pp = p + 1;
      return true;
    }
    if (c == '\\') {
      if (p + 1 >= end) return false;
      char e = p[1];
      if (e != '"' && e != '\\' && e != 'n' && e != 'r' && e != 't' &&
          e != 'b' && e != 'f')
        return false;
      p += 2;
      continue;
    }
    if (c < 0x20 || c > 0x7e) return false;
    p++;
  }
  return false;
}

// [0,"<own pubkey>",<created_at>,<kind>,[["tag",...],...],"<content>"]
static bool nostr_ev_parse(const char *s, size_t n, const char *pubhex,
                           nostr_ev_info *info) {
  const char *p = s;
  const char *end = s + n;
  uint32_t created = 0;
  const char *ts = NULL;
  size_t tl = 0;
  memset(info, 0, sizeof(*info));
  if (n < 70 || memcmp(p, "[0,\"", 4) != 0) {
    nostr_ev_err = "Not a NIP-01 event";
    return false;
  }
  p += 4;
  if (memcmp(p, pubhex, 64) != 0) {
    nostr_ev_err = "Pubkey is not this device";
    return false;
  }
  p += 64;
  if (!nostr_p_char(&p, end, '"') || !nostr_p_char(&p, end, ',')) {
    nostr_ev_err = "Bad pubkey field";
    return false;
  }
  if (!nostr_p_uint(&p, end, 0xFFFFFFFFu, &created) ||
      !nostr_p_char(&p, end, ',')) {
    nostr_ev_err = "Bad created_at";
    return false;
  }
  if (!nostr_p_uint(&p, end, 65535u, &info->kind) ||
      !nostr_p_char(&p, end, ',')) {
    nostr_ev_err = "Bad kind";
    return false;
  }
  if (!nostr_p_char(&p, end, '[')) {
    nostr_ev_err = "Bad tags";
    return false;
  }
  if (!nostr_p_char(&p, end, ']')) {
    for (;;) {
      if (!nostr_p_char(&p, end, '[') || !nostr_p_string(&p, end, &ts, &tl)) {
        nostr_ev_err = "Bad tag";
        return false;
      }
      if (info->tags >= NOSTR_TAGS_MAX) {
        nostr_ev_err = "Too many tags";
        return false;
      }
      info->letters[info->tags++] = (tl == 1) ? ts[0] : '*';
      while (nostr_p_char(&p, end, ',')) {
        if (!nostr_p_string(&p, end, &ts, &tl)) {
          nostr_ev_err = "Bad tag value";
          return false;
        }
      }
      if (!nostr_p_char(&p, end, ']')) {
        nostr_ev_err = "Bad tag end";
        return false;
      }
      if (nostr_p_char(&p, end, ',')) continue;
      if (!nostr_p_char(&p, end, ']')) {
        nostr_ev_err = "Bad tags end";
        return false;
      }
      break;
    }
  }
  if (!nostr_p_char(&p, end, ',') ||
      !nostr_p_string(&p, end, &info->content, &info->content_len)) {
    nostr_ev_err = "Bad content";
    return false;
  }
  if (info->content_len > NOSTR_CONTENT_MAX) {
    nostr_ev_err = "Content over 400 chars";
    return false;
  }
  if (!nostr_p_char(&p, end, ']') || p != end) {
    nostr_ev_err = "Trailing data";
    return false;
  }
  return true;
}

static const char *nostr_kind_name(uint32_t k) {
  switch (k) {
    case 0:
      return "profile";
    case 1:
      return "note";
    case 3:
      return "follows";
    case 4:
      return "DM(old)";
    case 5:
      return "delete";
    case 6:
      return "repost";
    case 7:
      return "reaction";
    default:
      return "";
  }
}

// Summary page, then the content as 80-char pages. Left = cancel, right = next.
static bool nostr_ev_confirm(const nostr_ev_info *in) {
  size_t pages = (in->content_len + 79) / 80;
  char title[24], a[24], b[24], c[24], d[24];
  size_t t = 0;
  memcpy(title, "Kind ", 5);
  t = 5 + nostr_ev_utoa(in->kind, title + 5);
  const char *kn = nostr_kind_name(in->kind);
  if (kn[0]) {
    title[t++] = ' ';
    size_t kl = strlen(kn);
    memcpy(title + t, kn, kl);
    t += kl;
  }
  title[t] = 0;
  if (in->tags) {
    memcpy(a, "Tags: ", 6);
    nostr_ev_utoa((uint32_t)in->tags, a + 6);
    memcpy(b, "types: ", 7);
    size_t shown = in->tags > 13 ? 12 : in->tags;
    memcpy(b + 7, in->letters, shown);
    b[7 + shown] = 0;
    if (in->tags > 13) {
      b[7 + shown] = '+';
      b[8 + shown] = 0;
    }
    memcpy(d, "tag values hidden", 18);
  } else {
    memcpy(a, "No tags", 8);
    b[0] = 0;
    d[0] = 0;
  }
  memcpy(c, "Text: ", 6);
  size_t cl = 6 + nostr_ev_utoa((uint32_t)in->content_len, c + 6);
  memcpy(c + cl, " chars", 7);
  const char *l1 = b[0] ? b : c;
  const char *l2 = b[0] ? c : NULL;
  const char *l3 = d[0] ? d : NULL;
  layoutDialogSwipe(NULL, _("Cancel"), pages ? _("Next") : _("Sign"), NULL,
                    title, a, l1, l2, l3, NULL);
  if (!protectButton(ButtonRequestType_ButtonRequest_ProtectCall, false)) {
    return false;
  }
  for (size_t pg = 0; pg < pages; pg++) {
    char head[24];
    char rows[4][21];
    memcpy(head, "Text ", 5);
    size_t h = 5 + nostr_ev_utoa((uint32_t)(pg + 1), head + 5);
    head[h++] = '/';
    h += nostr_ev_utoa((uint32_t)pages, head + h);
    head[h++] = ':';
    head[h] = 0;
    for (size_t row = 0; row < 4; row++) {
      size_t off = pg * 80 + row * 20;
      size_t take = 0;
      if (off < in->content_len) {
        take = in->content_len - off;
        if (take > 20) take = 20;
        memcpy(rows[row], in->content + off, take);
      }
      rows[row][take] = 0;
    }
    layoutDialogSwipe(NULL, _("Cancel"), (pg + 1 == pages) ? _("Sign") : _("Next"),
                      NULL, head, rows[0], rows[1][0] ? rows[1] : NULL,
                      rows[2][0] ? rows[2] : NULL, rows[3][0] ? rows[3] : NULL,
                      NULL);
    if (!protectButton(ButtonRequestType_ButtonRequest_ProtectCall, false)) {
      return false;
    }
  }
  return true;
}

// 0 ok, -1 key derivation failed (failure already sent), -2 bad input
// (nostr_ev_err says why), -3 cancelled on the device, -4 signing error.
static int nostr_ev_sign(char *out) {
  if (nostr_ev_want == 0 || nostr_ev_len != nostr_ev_want) {
    nostr_ev_err = "Event incomplete";
    return -2;
  }
  HDNode *node = nostr_node();
  if (!node) return -1;
  uint8_t pub[32];
  if (zkp_bip340_get_public_key(node->private_key, pub) != 0) return -4;
  char pubhex[65];
  nostr_hex(pub, sizeof(pub), pubhex);
  nostr_ev_info info;
  if (!nostr_ev_parse(nostr_ev, nostr_ev_len, pubhex, &info)) return -2;
  if (!nostr_ev_confirm(&info)) return -3;
  node = nostr_node();
  if (!node) return -1;
  uint8_t digest[32], sig[64], aux[32];
  sha256_Raw((const uint8_t *)nostr_ev, nostr_ev_len, digest);
  random_buffer(aux, sizeof(aux));
  if (zkp_bip340_sign_digest(node->private_key, digest, sig, aux) != 0) {
    return -4;
  }
  nostr_hex(digest, sizeof(digest), out);
  out[64] = ' ';
  nostr_hex(sig, sizeof(sig), out + 65);
  return 0;
}

// args = text after "NOSTREV ". Same return codes as nostr_ev_sign;
// on 0, out holds the reply text.
static int nostr_ev_command(const char *args, char *out) {
  uint32_t v = 0;
  const char *p = NULL;
  if (strncmp(args, "BEGIN ", 6) == 0) {
    p = args + 6;
    nostr_ev_reset();
    if (!nostr_p_uint(&p, p + strlen(p), NOSTR_EV_MAX, &v) || *p != 0 ||
        v < 70) {
      nostr_ev_err = "BEGIN needs a length";
      return -2;
    }
    nostr_ev_want = v;
    memcpy(out, "OK", 3);
    return 0;
  }
  if (strncmp(args, "ADD ", 4) == 0) {
    p = args + 4;
    if (nostr_ev_want == 0) {
      nostr_ev_err = "Send BEGIN first";
      return -2;
    }
    if (!nostr_p_uint(&p, p + strlen(p), NOSTR_EV_MAX, &v) || *p != ' ' ||
        v != nostr_ev_len) {
      nostr_ev_reset();
      nostr_ev_err = "Bad chunk offset";
      return -2;
    }
    p++;
    size_t dl = strlen(p);
    if (dl == 0 || nostr_ev_len + dl > nostr_ev_want) {
      nostr_ev_reset();
      nostr_ev_err = "Bad chunk size";
      return -2;
    }
    memcpy(nostr_ev + nostr_ev_len, p, dl);
    nostr_ev_len += dl;
    nostr_ev[nostr_ev_len] = 0;
    memcpy(out, "OK ", 3);
    nostr_ev_utoa((uint32_t)nostr_ev_len, out + 3);
    return 0;
  }
  if (strcmp(args, "SIGN") == 0) {
    int r = nostr_ev_sign(out);
    nostr_ev_reset();
    return r;
  }
  nostr_ev_reset();
  nostr_ev_err = "Use BEGIN, ADD or SIGN";
  return -2;
}

'''

COMMAND = r'''  // Nostr experiment: "NOSTREV BEGIN|ADD|SIGN ..." signs a full NIP-01 event after on-device review
  if (msg->has_message && strncmp(msg->message, "NOSTREV ", 8) == 0) {
    CHECK_INITIALIZED
    CHECK_PIN
    int ev_r = nostr_ev_command(msg->message + 8, resp->message);
    if (ev_r == -1) return;
    if (ev_r == -2) {
      fsm_sendFailure(FailureType_Failure_DataError, nostr_ev_err);
      layoutHome();
      return;
    }
    if (ev_r == -3) {
      fsm_sendFailure(FailureType_Failure_ActionCancelled, NULL);
      layoutHome();
      return;
    }
    if (ev_r != 0) {
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
  echo "Copy firmware/trezor.bin to your PC under a NEW name, check the hash, flash it, then use nostr_send.py"
fi

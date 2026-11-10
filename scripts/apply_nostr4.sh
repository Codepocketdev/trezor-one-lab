#!/usr/bin/env bash
# apply_nostr4.sh - Trezor Model One experiment 02, step 5: show tag VALUES on the device.
# After the summary page, the device now shows every tag exactly as it will be hashed
# (for example ["p","<64 hex>"]) in 80-character pages, and signs only after you press
# the button on every page. Closes the gap where a PC could swap a p/e tag unseen.
# Run AFTER apply_nostr3.sh (re-running apply_nostr3.sh removes this patch).
# Usage: ./apply_nostr4.sh [--build] [--revert] [REPO_DIR]   --build also builds the DEVICE firmware
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
BACKUP="$FSMCOMMON.pre-nostr4"

[ -f "$FSMCOMMON" ] || { echo "ERROR: cannot find $FSMCOMMON" >&2; exit 1; }

if [ "$REVERT" -eq 1 ]; then
  [ -f "$BACKUP" ] && cp "$BACKUP" "$FSMCOMMON" && echo "restored fsm_msg_common.h from before the tag-display patch" || echo "no backup, nothing to do"
  exit 0
fi

if grep -q "tag_at" "$FSMCOMMON"; then
  echo "already patched, skipping the edit"
else
  grep -q "nostr_ev_command" "$FSMCOMMON" || { echo "ERROR: run apply_nostr3.sh first" >&2; exit 1; }
  [ -f "$BACKUP" ] || cp "$FSMCOMMON" "$BACKUP"

  python3 - "$FSMCOMMON" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()


def once(old, new):
    global src
    if src.count(old) != 1:
        sys.exit("ERROR: expected exactly one of this text, found %d:\n%s" % (src.count(old), old))
    src = src.replace(old, new)


once("  char letters[NOSTR_TAGS_MAX + 1];\n  const char *content;",
     "  char letters[NOSTR_TAGS_MAX + 1];\n"
     "  const char *tag_at[NOSTR_TAGS_MAX];\n"
     "  size_t tag_len[NOSTR_TAGS_MAX];\n"
     "  const char *content;")

once("      if (!nostr_p_char(&p, end, '[') || !nostr_p_string(&p, end, &ts, &tl)) {\n"
     "        nostr_ev_err = \"Bad tag\";",
     "      const char *tag_begin = p;\n"
     "      if (!nostr_p_char(&p, end, '[') || !nostr_p_string(&p, end, &ts, &tl)) {\n"
     "        nostr_ev_err = \"Bad tag\";")

once("        nostr_ev_err = \"Bad tag end\";\n        return false;\n      }\n",
     "        nostr_ev_err = \"Bad tag end\";\n        return false;\n      }\n"
     "      info->tag_at[info->tags - 1] = tag_begin;\n"
     "      info->tag_len[info->tags - 1] = (size_t)(p - tag_begin);\n")

once('    memcpy(d, "tag values hidden", 18);',
     '    memcpy(d, "values on next pages", 21);')

once('  layoutDialogSwipe(NULL, _("Cancel"), pages ? _("Next") : _("Sign"), NULL,',
     '  layoutDialogSwipe(NULL, _("Cancel"), (pages || in->tags) ? _("Next") : _("Sign"), NULL,')

TAGLOOP = r'''  // every tag, exactly as it will be hashed, 80 characters per page
  for (size_t ti = 0; ti < in->tags; ti++) {
    size_t tlen = in->tag_len[ti];
    size_t tpages = (tlen + 79) / 80;
    for (size_t pg = 0; pg < tpages; pg++) {
      char head[24];
      char rows[4][21];
      size_t h = 0;
      memcpy(head, "Tag ", 4);
      h = 4;
      h += nostr_ev_utoa((uint32_t)(ti + 1), head + h);
      head[h++] = '/';
      h += nostr_ev_utoa((uint32_t)in->tags, head + h);
      if (tpages > 1) {
        head[h++] = ' ';
        h += nostr_ev_utoa((uint32_t)(pg + 1), head + h);
        head[h++] = '/';
        h += nostr_ev_utoa((uint32_t)tpages, head + h);
      }
      head[h++] = ':';
      head[h] = 0;
      for (size_t row = 0; row < 4; row++) {
        size_t off = pg * 80 + row * 20;
        size_t take = 0;
        if (off < tlen) {
          take = tlen - off;
          if (take > 20) take = 20;
          memcpy(rows[row], in->tag_at[ti] + off, take);
        }
        rows[row][take] = 0;
      }
      bool final_page = (ti + 1 == in->tags) && (pg + 1 == tpages) && pages == 0;
      layoutDialogSwipe(NULL, _("Cancel"), final_page ? _("Sign") : _("Next"),
                        NULL, head, rows[0], rows[1][0] ? rows[1] : NULL,
                        rows[2][0] ? rows[2] : NULL, rows[3][0] ? rows[3] : NULL,
                        NULL);
      if (!protectButton(ButtonRequestType_ButtonRequest_ProtectCall, false)) {
        return false;
      }
    }
  }
'''
once("  for (size_t pg = 0; pg < pages; pg++) {\n    char head[24];",
     TAGLOOP + "  for (size_t pg = 0; pg < pages; pg++) {\n    char head[24];")

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
  echo "NOSTREV in binary: $(grep -a -c NOSTREV "$REPO/legacy/firmware/trezor.bin")   'values on next pages' in binary: $(grep -a -c 'values on next pages' "$REPO/legacy/firmware/trezor.bin")"
  echo "Copy firmware/trezor.bin to your PC under a NEW name, check the hash, flash it."
fi

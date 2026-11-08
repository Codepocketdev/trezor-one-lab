#!/usr/bin/env bash
# apply_clock3.sh - clock + date home screen for the Trezor Model One (legacy) firmware,
# with a USB "set time" command (sent inside a Ping message) and a settime helper.
# Usage: ./apply_clock3.sh [--build] [--revert] [REPO_DIR]
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
LAYOUT="$FW/layout2.c"
TREZOR="$FW/trezor.c"
FSMCOMMON="$FW/fsm_msg_common.h"
OLEDH="$REPO/legacy/oled.h"
FILES=("$LAYOUT" "$TREZOR" "$FSMCOMMON")

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: cannot find $f" >&2
    echo "Pass the repo path, e.g.: $0 ~/trezor-firmware" >&2
    exit 1
  fi
done

restore() {
  for f in "${FILES[@]}"; do
    if [ -f "$f.orig" ]; then
      cp "$f.orig" "$f"
      echo "restored pristine $(basename "$f")"
    fi
  done
}

if [ "$REVERT" -eq 1 ]; then
  restore
  exit 0
fi

for f in "${FILES[@]}"; do
  [ -f "$f.orig" ] || cp "$f" "$f.orig"
done
restore

DOUBLE=0
if [ -f "$OLEDH" ] && grep -q "define FONT_DOUBLE" "$OLEDH"; then
  DOUBLE=1
else
  echo "FONT_DOUBLE not found in oled.h, using the standard font for the time"
fi

python3 - "$LAYOUT" "$TREZOR" "$FSMCOMMON" "$DOUBLE" <<'PYEOF'
import re
import sys

layout_path, trezor_path, fsm_path, double = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"


def fail(msg):
    print("ERROR: " + msg, file=sys.stderr)
    print("Files may be partly patched. Run ./apply_clock3.sh --revert to restore them.", file=sys.stderr)
    sys.exit(1)


TIME_FONT = "FONT_STANDARD | FONT_DOUBLE" if double else "FONT_STANDARD"
TIME_Y = 16 if double else 24
DATE_Y = 42

HELPER = r'''static inline int32_t clock_days_from_civil(int y, int m, int d) {
  y -= m <= 2;
  int era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (unsigned)((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1);
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int32_t)doe - 719468;
}

static void clock_civil_from_days(int32_t z, int *y, unsigned *m, unsigned *d) {
  z += 719468;
  int era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  *d = doy - (153 * mp + 2) / 5 + 1;
  *m = mp < 10 ? mp + 3 : mp - 9;
  *y = (int)yoe + era * 400 + (*m <= 2);
}

// Elapsed milliseconds since boot, tolerant of the 32-bit counter wrapping
static uint64_t clock_total_ms = 0;
static uint32_t clock_last_ms = 0;

// Time pushed from the host with "SETTIME <utc_unix_seconds> [<utc_offset_seconds>]"
static bool clock_set_valid = false;
static uint64_t clock_set_local_secs = 0;
static uint64_t clock_set_at_ms = 0;

static void clock_tick(void) {
  uint32_t now_ms = timer_ms();
  clock_total_ms += (uint32_t)(now_ms - clock_last_ms);
  clock_last_ms = now_ms;
}

bool layoutClockSetFromText(const char *text);
bool layoutClockSetFromText(const char *text) {
  const char *p = text;
  const char *prefix = "SETTIME ";
  for (const char *q = prefix; *q; q++, p++) {
    if (*p != *q) return false;
  }
  uint64_t utc = 0;
  int digits = 0;
  while (*p >= '0' && *p <= '9') {
    utc = utc * 10 + (uint64_t)(*p - '0');
    p++;
    if (++digits > 12) return false;
  }
  if (digits == 0 || utc < 1700000000u) return false;  // sanity: after Nov 2023
  int64_t offset = 0;
  if (*p == ' ') {
    p++;
    bool neg = false;
    if (*p == '-') {
      neg = true;
      p++;
    } else if (*p == '+') {
      p++;
    }
    int64_t v = 0;
    int od = 0;
    while (*p >= '0' && *p <= '9') {
      v = v * 10 + (*p - '0');
      p++;
      if (++od > 6) return false;
    }
    if (od == 0) return false;
    offset = neg ? -v : v;
  }
  clock_tick();
  clock_set_local_secs = (uint64_t)((int64_t)utc + offset);
  clock_set_at_ms = clock_total_ms;
  clock_set_valid = true;
  return true;
}

static void layoutDrawClock(void) {
  clock_tick();

  uint64_t secs;
  if (clock_set_valid) {
    // time sent from the host, counted forward
    secs = clock_set_local_secs + (clock_total_ms - clock_set_at_ms) / 1000u;
  } else {
#if EMULATOR
    // emulator only: use the host clock (UTC) shifted to East Africa Time (UTC+3)
    secs = (uint64_t)time(NULL) + 3 * 3600;
#else
    // device: start from the build date and time
    // __DATE__ = "Nov  7 2026", __TIME__ = "HH:MM:SS"
    static const char months[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
    int mon = 1;
    for (int i = 0; i < 12; i++) {
      if (__DATE__[0] == months[i * 3] && __DATE__[1] == months[i * 3 + 1] &&
          __DATE__[2] == months[i * 3 + 2]) {
        mon = i + 1;
        break;
      }
    }
    int day = (__DATE__[4] == ' ' ? 0 : __DATE__[4] - '0') * 10 + (__DATE__[5] - '0');
    int year = (__DATE__[7] - '0') * 1000 + (__DATE__[8] - '0') * 100 +
               (__DATE__[9] - '0') * 10 + (__DATE__[10] - '0');
    uint32_t base_s = ((__TIME__[0] - '0') * 10 + (__TIME__[1] - '0')) * 3600 +
                      ((__TIME__[3] - '0') * 10 + (__TIME__[4] - '0')) * 60 +
                      ((__TIME__[6] - '0') * 10 + (__TIME__[7] - '0'));
    secs = (uint64_t)clock_days_from_civil(year, mon, day) * 86400u + base_s +
           clock_total_ms / 1000u;
#endif
  }

  int32_t days = (int32_t)(secs / 86400u);
  uint32_t sod = (uint32_t)(secs % 86400u);

  int y;
  unsigned m, d;
  clock_civil_from_days(days, &y, &m, &d);

  static const char wd[] = "SunMonTueWedThuFriSat";
  static const char mn[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
  unsigned w = (unsigned)((days + 4) % 7);  // 1970-01-01 was a Thursday

  char tbuf[9];
  snprintf(tbuf, sizeof(tbuf), "%02u:%02u:%02u", (unsigned)(sod / 3600),
           (unsigned)((sod / 60) % 60), (unsigned)(sod % 60));
  char dbuf[20];
  snprintf(dbuf, sizeof(dbuf), "%.3s %02u %.3s %04d", wd + w * 3, d,
           mn + (m - 1) * 3, y);

  oledDrawStringCenter(OLED_WIDTH / 2, @TIME_Y@, tbuf, @TIME_FONT@);
  oledDrawStringCenter(OLED_WIDTH / 2, @DATE_Y@, dbuf, FONT_STANDARD);
}

'''.replace("@TIME_Y@", str(TIME_Y)).replace("@TIME_FONT@", TIME_FONT).replace("@DATE_Y@", str(DATE_Y))

REFRESH = '''  // clock: redraw the home screen once per second
  {
    static uint32_t last_clock_sec = 0xFFFFFFFF;
    if (layoutLast == layoutHomescreen) {
      uint32_t s = timer_ms() / 1000;
      if (s != last_clock_sec) {
        last_clock_sec = s;
        layoutHomescreen();
      }
    }
  }

'''

# ---------- layout2.c ----------
with open(layout_path) as f:
    src = f.read()

sig = "void layoutHomescreen(void) {"
if src.count(sig) != 1:
    fail("expected exactly one '%s' in layout2.c (found %d)" % (sig, src.count(sig)))
i = src.index(sig)
nxt = src.find("void layoutBusyscreen(void) {", i)
end = nxt if nxt != -1 else len(src)

a1 = "  char label[MAX_LABEL_LEN + 1]"
a2 = "  bool no_backup = false;"
p1 = src.find(a1, i)
p2 = src.find(a2, i)
if p1 < 0 or p1 > end:
    fail("could not find the label/logo block start in layoutHomescreen")
if p2 < 0 or p2 > end or p2 < p1:
    fail("could not find the backup-banner block in layoutHomescreen")

src = src[:p2] + "#endif\n  layoutDrawClock();\n\n" + src[p2:]
src = src[:p1] + "#if 0  // logo, label and custom homescreen disabled for the clock\n" + src[p1:]
src = src[:i] + HELPER + src[i:]

extra = ""
for inc in ("#include <stdio.h>", "#include <time.h>"):
    if inc not in src:
        extra += inc + "\n"
if extra:
    m = re.search(r"^#include", src, re.M)
    if not m:
        fail("no #include found in layout2.c")
    src = src[:m.start()] + extra + src[m.start():]

with open(layout_path, "w") as f:
    f.write(src)
print("patched layout2.c")

# ---------- trezor.c ----------
with open(trezor_path) as f:
    src = f.read()

anchor = "  // if homescreen is shown for too long\n"
if src.count(anchor) != 1:
    fail("expected exactly one '// if homescreen is shown for too long' in trezor.c (found %d)"
         % src.count(anchor))
k = src.index(anchor)
src = src[:k] + REFRESH + src[k:]
with open(trezor_path, "w") as f:
    f.write(src)
print("patched trezor.c")

k = src.index("last_clock_sec")
funcs = re.findall(r"^[A-Za-z_][\w \*]*\b(\w+)\s*\([^;{]*\)\s*\{", src[:k], re.M)
if funcs:
    name = funcs[-1]
    called = len(re.findall(r"\b%s\s*\(" % re.escape(name), src)) > 1
    print("clock refresh lives in: %s()  (called elsewhere in trezor.c: %s)"
          % (name, "yes" if called else "NO - check it runs from the main loop"))

# ---------- fsm_msg_common.h (Ping handler) ----------
with open(fsm_path) as f:
    src = f.read()

sig = "void fsm_msgPing(const Ping *msg) {"
if src.count(sig) != 1:
    fail("expected exactly one '%s' in fsm_msg_common.h (found %d)" % (sig, src.count(sig)))
i = src.index(sig)
anchor = "  if (msg->has_message) {\n    resp->has_message = true;"
j = src.find(anchor, i)
if j < 0:
    fail("could not find the has_message block inside fsm_msgPing")

SETTIME = '''  // "SETTIME <utc_unix_seconds> [<utc_offset_seconds>]" sets the home screen clock
  if (msg->has_message) {
    layoutClockSetFromText(msg->message);
  }

'''
src = src[:j] + SETTIME + src[j:]
src = "bool layoutClockSetFromText(const char *text);\n\n".join([src[:i], src[i:]])
with open(fsm_path, "w") as f:
    f.write(src)
print("patched fsm_msg_common.h")
PYEOF

cat > "$HOME/settime.sh" <<'SETTIME_EOF'
#!/usr/bin/env bash
# settime.sh - send the current time to a Trezor running the clock firmware.
# Usage: ./settime.sh [--emulator]    (TZ_NAME defaults to Africa/Nairobi)
set -euo pipefail
REPO="${REPO:-$HOME/trezor-firmware}"
TZ_NAME="${TZ_NAME:-Africa/Nairobi}"
PORT=()
[ "${1:-}" = "--emulator" ] && PORT=(-p udp)

UTC=$(date -u +%s)
Z=$(TZ="$TZ_NAME" date +%z)
SIGN=${Z:0:1}; H=${Z:1:2}; M=${Z:3:2}
OFF=$(( 10#$H * 3600 + 10#$M * 60 ))
[ "$SIGN" = "-" ] && OFF=$(( -OFF ))

cd "$REPO/legacy"
uv run trezorctl "${PORT[@]}" ping "SETTIME $UTC $OFF"
echo "sent: SETTIME $UTC $OFF  ($TZ_NAME)"
SETTIME_EOF
chmod +x "$HOME/settime.sh"
echo "created ~/settime.sh"

echo
echo "Done. Diff summary:"
git -C "$REPO" diff --stat -- legacy/firmware/layout2.c legacy/firmware/trezor.c legacy/firmware/fsm_msg_common.h || true

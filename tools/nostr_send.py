#!/usr/bin/env python3
"""Send a Nostr event to the Trezor lab firmware (NOSTREV) and print the signed event.

Usage:
  python nostr_send.py "hello world"
  python nostr_send.py "hello" --kind 1 --tag t,nostr --tag p,<64 hex>
Plain ASCII only, content up to 400 chars, up to 20 tags. Review every page on the device.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time

P = (1 << 256) - (1 << 32) - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def _add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def _mul(k, p=G):
    r = None
    while k:
        if k & 1:
            r = _add(r, p)
        p = _add(p, p)
        k >>= 1
    return r


def _tagged(tag, data):
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + data).digest()


def verify(pub, msg, sig):
    """BIP-340 verification."""
    x = int.from_bytes(pub, "big")
    y2 = (pow(x, 3, P) + 7) % P
    y = pow(y2, (P + 1) // 4, P)
    if pow(y, 2, P) != y2:
        return False
    pt = (x, y if y % 2 == 0 else P - y)
    r, s = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
    if r >= P or s >= N:
        return False
    e = int.from_bytes(_tagged("BIP0340/challenge", sig[:32] + pub + msg), "big") % N
    pt2 = _add(_mul(s), _mul(N - e, pt))
    return pt2 is not None and pt2[1] % 2 == 0 and pt2[0] == r


ESC = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t",
       "\b": "\\b", "\f": "\\f"}


def esc(s):
    out = []
    for ch in s:
        if ch in ESC:
            out.append(ESC[ch])
        elif 0x20 <= ord(ch) <= 0x7E:
            out.append(ch)
        else:
            sys.exit("Only plain ASCII is supported for now (got %r)" % ch)
    return "".join(out)


def tz(message):
    exe = shutil.which("trezorctl")
    if not exe:
        sys.exit("trezorctl was not found on PATH")
    r = subprocess.run([exe, "ping", message], capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    if r.returncode != 0:
        sys.exit("Device said no: " + " ".join((r.stderr + " " + r.stdout).split()))
    return lines[-1].strip() if lines else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("content")
    ap.add_argument("--kind", type=int, default=1)
    ap.add_argument("--tag", action="append", default=[],
                    help="name,value[,value...]  (repeatable)")
    args = ap.parse_args()
    if len(args.content) > 400:
        sys.exit("Content is over 400 characters")
    pub = tz("NOSTRPUB")
    if len(pub) != 64 or any(c not in "0123456789abcdef" for c in pub):
        sys.exit("Unexpected NOSTRPUB reply: %r" % pub)
    tags = [t.split(",") for t in args.tag]
    created_at = int(time.time())
    tag_json = "[" + ",".join("[" + ",".join('"%s"' % esc(x) for x in t) + "]"
                              for t in tags) + "]"
    ser = '[0,"%s",%d,%d,%s,"%s"]' % (pub, created_at, args.kind, tag_json,
                                      esc(args.content))
    if len(ser) > 900:
        sys.exit("Event is over 900 bytes")
    print("Event to sign (%d bytes):\n%s\n" % (len(ser), ser))
    if not tz("NOSTREV BEGIN %d" % len(ser)).startswith("OK"):
        sys.exit("This firmware has no NOSTREV support. Flash the newer build first.")
    for off in range(0, len(ser), 180):
        tz("NOSTREV ADD %d %s" % (off, ser[off:off + 180]))
    print("Sent. Review every page on the device, then press the right button to sign.")
    reply = tz("NOSTREV SIGN").split()
    if len(reply) != 2:
        sys.exit("Unexpected reply: %r" % reply)
    eid, sig = reply
    want = hashlib.sha256(ser.encode()).hexdigest()
    ok_id = eid == want
    ok_sig = verify(bytes.fromhex(pub), bytes.fromhex(eid), bytes.fromhex(sig))
    print("id matches our own hash :", ok_id)
    print("signature verifies      :", ok_sig)
    event = {"id": eid, "pubkey": pub, "created_at": created_at, "kind": args.kind,
             "tags": tags, "content": args.content, "sig": sig}
    text = json.dumps(event, separators=(",", ":"))
    with open("nostr_event.json", "w") as f:
        f.write(text + "\n")
    print("\nSigned event (also saved to nostr_event.json):\n" + text)
    if not (ok_id and ok_sig):
        sys.exit("CHECK FAILED - do not publish this event")


main()

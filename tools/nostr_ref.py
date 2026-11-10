#!/usr/bin/env python3
"""nostr_ref.py - pure-Python reference for the Trezor Model One Nostr signer experiment.
TEST MNEMONICS ONLY. Slow and not constant-time: never use it with a real key.
  python3 nostr_ref.py key  "<mnemonic>"                      -> NIP-06 key at m/44'/1237'/0'/0/0
  python3 nostr_ref.py sign "<mnemonic>" "<content>" [created_at] [kind]
  python3 nostr_ref.py verify <pubkey_hex> <id_hex> <sig_hex>
"""
import hashlib, hmac, json, sys, time

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)

def add(a, b):
    if a is None: return b
    if b is None: return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0: return None
    if a == b: l = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else: l = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (l * l - a[0] - b[0]) % P
    return (x, (l * (a[0] - x) - a[1]) % P)

def mul(k, pt=G):
    r = None
    while k:
        if k & 1: r = add(r, pt)
        pt = add(pt, pt); k >>= 1
    return r

def tagged(tag, data):
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + data).digest()

def lift_x(x):
    y2 = (pow(x, 3, P) + 7) % P
    y = pow(y2, (P + 1) // 4, P)
    if y * y % P != y2: return None
    return (x, y if y % 2 == 0 else P - y)

def schnorr_pub(sk): return mul(sk)[0].to_bytes(32, "big")

def schnorr_sign(sk, msg, aux=bytes(32)):
    pt = mul(sk); d = sk if pt[1] % 2 == 0 else N - sk
    t = (d ^ int.from_bytes(tagged("BIP0340/aux", aux), "big")).to_bytes(32, "big")
    k = int.from_bytes(tagged("BIP0340/nonce", t + pt[0].to_bytes(32, "big") + msg), "big") % N
    r = mul(k); k = k if r[1] % 2 == 0 else N - k
    e = int.from_bytes(tagged("BIP0340/challenge", r[0].to_bytes(32, "big") + pt[0].to_bytes(32, "big") + msg), "big") % N
    return r[0].to_bytes(32, "big") + ((k + e * d) % N).to_bytes(32, "big")

def schnorr_verify(pub, msg, sig):
    pt = lift_x(int.from_bytes(pub, "big"))
    r, s = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
    if pt is None or r >= P or s >= N: return False
    e = int.from_bytes(tagged("BIP0340/challenge", sig[:32] + pub + msg), "big") % N
    R = add(mul(s), mul(N - e, pt))
    return R is not None and R[1] % 2 == 0 and R[0] == r

def bip32_priv(seed, path):
    I = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
    k, c = int.from_bytes(I[:32], "big"), I[32:]
    for step in path.split("/")[1:]:
        hard = step.endswith("'"); i = int(step.rstrip("'")) + (0x80000000 if hard else 0)
        data = (b"\x00" + k.to_bytes(32, "big") if hard else b"\x02" + mul(k)[0].to_bytes(32, "big") if mul(k)[1] % 2 == 0 else b"\x03" + mul(k)[0].to_bytes(32, "big"))
        I = hmac.new(c, data + i.to_bytes(4, "big"), hashlib.sha512).digest()
        k, c = (int.from_bytes(I[:32], "big") + k) % N, I[32:]
    return k

def nip06_key(mnemonic, passphrase="", account=0):
    seed = hashlib.pbkdf2_hmac("sha512", mnemonic.encode(), ("mnemonic" + passphrase).encode(), 2048)
    return bip32_priv(seed, f"m/44'/1237'/{account}'/0/0")

def event_id(pub_hex, created_at, kind, tags, content):
    s = json.dumps([0, pub_hex, created_at, kind, tags, content], separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(s.encode()).digest(), s

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["key"]:
        sk = nip06_key(a[1]); print("private:", sk.to_bytes(32, "big").hex()); print("public :", schnorr_pub(sk).hex())
    elif a[:1] == ["sign"]:
        sk = nip06_key(a[1]); pub = schnorr_pub(sk).hex()
        ts = int(a[3]) if len(a) > 3 else int(time.time()); kind = int(a[4]) if len(a) > 4 else 1
        eid, ser = event_id(pub, ts, kind, [], a[2]); sig = schnorr_sign(sk, eid)
        print("serialized:", ser); print("id        :", eid.hex()); print("sig       :", sig.hex()); print("pubkey    :", pub)
        print(json.dumps({"id": eid.hex(), "pubkey": pub, "created_at": ts, "kind": kind, "tags": [], "content": a[2], "sig": sig.hex()}, ensure_ascii=False))
    elif a[:1] == ["verify"]:
        print("VALID" if schnorr_verify(bytes.fromhex(a[1]), bytes.fromhex(a[2]), bytes.fromhex(a[3])) else "INVALID")
    else:
        print(__doc__)

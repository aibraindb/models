#!/usr/bin/env python3
import argparse, base64, hashlib, json, pathlib, sys, getpass
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

BUF=1024*1024
def sha256_path(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for b in iter(lambda: f.read(BUF), b""): h.update(b)
    return h.hexdigest()

def derive_key(pw,salt,rounds):
    return PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=rounds).derive(pw)

def main():
    ap=argparse.ArgumentParser(description="Reassemble & decrypt chunked file")
    ap.add_argument("chunks_dir"); ap.add_argument("--out",default=None)
    ap.add_argument("--passphrase",default=None)
    a=ap.parse_args()
    d=pathlib.Path(a.chunks_dir)
    man=json.loads((d/"manifest.json").read_text(encoding="utf-8"))
    out=pathlib.Path(a.out or man["original_filename"])

    pw=(a.passphrase or getpass.getpass("Passphrase: ")).encode("utf-8")
    salt=base64.b64decode(man["salt_b64"]); rounds=int(man["kdf"]["rounds"])
    key=derive_key(pw,salt,rounds)

    with open(out,"wb") as w:
        for ch in man["chunks"]:
            p=d/ch["name"]; raw=p.read_bytes()
            nonce,ct=raw[:12], raw[12:]
            if hashlib.sha256(ct).hexdigest()!=ch["sha256"]:
                print(f"Hash mismatch: {p}", file=sys.stderr); sys.exit(3)
            pt=AESGCM(key).decrypt(nonce, ct, man["original_filename"].encode())
            w.write(pt)

    ok_size=out.stat().st_size==man["original_size"]
    ok_hash=sha256_path(out)==man["original_sha256"]
    print(f"Wrote {out} ({out.stat().st_size} bytes)")
    print(f"Size match: {ok_size}, SHA256 match: {ok_hash}")
    if not (ok_size and ok_hash):
        print("❌ Integrity check failed.", file=sys.stderr); sys.exit(4)
    print("✅ Reassembly verified.")
if __name__=="__main__": main()

#!/usr/bin/env python3
"""Decrypt a BackupAutomation .enc file without PowerShell (Linux/macOS/Windows).

Emergency path for when no Windows machine is at hand. Needs Python 3.6+ and the
`cryptography` package (pip install cryptography). The file format is documented in
lib/BackupNative.cs.

    python3 decrypt-backup.py main_db_20261025_020001.fbk.enc main_db.fbk

The passphrase is read from the terminal. The plaintext file is only kept if the
integrity check (HMAC over the whole file) succeeds.
"""
import getpass
import hashlib
import hmac
import os
import struct
import sys

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

PREFIX, CHECK, TAG, CHUNK = 44, 16, 32, 1024 * 1024


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    if os.path.exists(dst):
        sys.exit("target already exists: " + dst)
    size = os.path.getsize(src)
    cipher_len = size - PREFIX - CHECK - TAG
    if cipher_len < 16 or cipher_len % 16:
        sys.exit("not an encrypted backup file, or truncated")
    passphrase = getpass.getpass("Backup passphrase: ").encode("utf-8")

    with open(src, "rb") as f:
        prefix = f.read(PREFIX)
        check = f.read(CHECK)
        if prefix[:8] != b"BKAENC01":
            sys.exit("unknown header - not a BackupAutomation file")
        iterations = struct.unpack("<i", prefix[8:12])[0]
        keys = hashlib.pbkdf2_hmac("sha256", passphrase, prefix[12:28], iterations, 64)
        enc_key, mac_key = keys[:32], keys[32:]
        expected = hmac.new(mac_key, b"BKAENC01-keycheck" + prefix, "sha256").digest()[:CHECK]
        if not hmac.compare_digest(expected, check):
            sys.exit("wrong passphrase")

        mac = hmac.new(mac_key, prefix + check, "sha256")
        decryptor = Cipher(algorithms.AES(enc_key), modes.CBC(prefix[28:44])).decryptor()
        unpadder = padding.PKCS7(128).unpadder()
        ok = False
        try:
            with open(dst, "xb") as out:
                remaining = cipher_len
                while remaining:
                    block = f.read(min(CHUNK, remaining))
                    if not block:
                        raise ValueError("unexpected end of file")
                    remaining -= len(block)
                    mac.update(block)
                    out.write(unpadder.update(decryptor.update(block)))
                if not hmac.compare_digest(mac.digest(), f.read(TAG)):
                    raise ValueError("integrity check failed: file corrupted or modified")
                out.write(unpadder.update(decryptor.finalize()) + unpadder.finalize())
            ok = True
        except ValueError as e:
            sys.exit(str(e))
        finally:
            if not ok and os.path.exists(dst):
                os.remove(dst)
    print("OK:", dst)


if __name__ == "__main__":
    main()

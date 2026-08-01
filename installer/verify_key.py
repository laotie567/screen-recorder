#!/usr/bin/env python3
"""验证 extension/manifest.json 的 "key"(公钥)与 installer/install.sh 的 EXTENSION_ID 匹配。

Chrome 扩展 ID = SHA-256(公钥 SPKI DER) 前 32 个 hex 字符,
每个 hex 字符映射到 a-p(0→a ... 9→j, a→k ... f→p)。
用法:python3 verify_key.py
退出码 0 = 匹配;1 = 不匹配或解析失败。
"""
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HEX_TO_ID = {hex(i)[2:]: chr(ord("a") + i) for i in range(16)}


def main():
    # 1. 从 manifest.json 提取公钥
    manifest = json.load(open(os.path.join(ROOT, "extension", "manifest.json")))
    pub_pem = manifest["key"]
    if "-----BEGIN PUBLIC KEY-----" not in pub_pem:
        print("FAIL: manifest key is not a PEM public key")
        return 1

    # 2. 从 install.sh 提取 EXTENSION_ID
    install_sh = open(os.path.join(ROOT, "installer", "install.sh")).read()
    m = re.search(r'EXTENSION_ID="([a-p]{32})"', install_sh)
    if not m:
        print("FAIL: cannot find EXTENSION_ID in install.sh")
        return 1
    expected_id = m.group(1)

    # 3. 公钥 → DER → SHA-256 → a-p ID
    proc = subprocess.run(
        ["openssl", "pkey", "-pubin", "-inform", "PEM", "-outform", "DER"],
        input=pub_pem.encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        print("FAIL: openssl cannot parse manifest public key:", proc.stderr.decode()[:200])
        return 1
    digest = hashlib.sha256(proc.stdout).hexdigest()[:32]
    actual_id = "".join(HEX_TO_ID[c] for c in digest)

    print("manifest key  -> extension_id:", actual_id)
    print("install.sh    -> EXTENSION_ID :", expected_id)
    if actual_id == expected_id:
        print("PASS: key ↔ EXTENSION_ID 匹配")
        return 0
    print("FAIL: 不匹配!请用 generate_key.py 重新生成并同步两处")
    return 1


if __name__ == "__main__":
    sys.exit(main())

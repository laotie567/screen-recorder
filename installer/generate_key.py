#!/usr/bin/env python3
"""重新生成扩展 key 并计算扩展 ID(安全修复:私钥不再入库,只留在本机)。

用法:python3 generate_key.py <输出目录>
输出:输出目录/extension-key.pem(私钥,勿提交)、extension-key.pub.pem(公钥,用于 manifest)、扩展 ID
"""
import hashlib
import subprocess
import sys

HEX_TO_ID = {hex(i)[2:]: chr(ord("a") + i) for i in range(16)}


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    key_path = out_dir + "/extension-key.pem"
    pub_path = out_dir + "/extension-key.pub.pem"
    subprocess.run(
        ["openssl", "genrsa", "-out", key_path, "2048"], check=True, capture_output=True
    )
    subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-pubout", "-out", pub_path],
        check=True,
        capture_output=True,
    )
    der = subprocess.run(
        ["openssl", "rsa", "-in", key_path, "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    digest = hashlib.sha256(der).hexdigest()[:32]
    ext_id = "".join(HEX_TO_ID[c] for c in digest)
    pub_pem = open(pub_path).read()

    print("extension_id:", ext_id)
    print("private_key:", key_path, "(勿提交到仓库)")
    print("public_key:", pub_path)
    print()
    print('manifest.json 的 "key" 字段(粘贴时转义换行为 \\n):')
    print(pub_pem)


if __name__ == "__main__":
    main()

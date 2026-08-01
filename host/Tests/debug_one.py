#!/usr/bin/env python3
"""单独调试 test-mixer 命令:打印响应、退出码与 stderr。"""
import json
import os
import struct
import subprocess
import sys

BIN = sys.argv[1] if len(sys.argv) > 1 else ".build/debug/ScreenRecordHost"
CMD = sys.argv[2] if len(sys.argv) > 2 else "test-mixer"

env = dict(os.environ, SCREENRECORDHOST_NO_APPKIT="1")
proc = subprocess.Popen(
    [BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
)
payload = json.dumps({"cmd": CMD}).encode()
proc.stdin.write(struct.pack("<I", len(payload)))
proc.stdin.write(payload)
proc.stdin.flush()

header = proc.stdout.read(4)
print("header:", header)
if header:
    n = struct.unpack("<I", header)[0]
    print("resp:", proc.stdout.read(n).decode(errors="replace"))
try:
    proc.stdin.close()
except BrokenPipeError:
    pass
proc.wait(timeout=10)
print("returncode:", proc.returncode)
err = proc.stderr.read().decode(errors="replace")
print("stderr:", err[:3000])

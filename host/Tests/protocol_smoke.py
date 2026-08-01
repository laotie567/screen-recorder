#!/usr/bin/env python3
"""Native messaging 协议冒烟测试:向宿主进程发送命令,校验响应。"""
import json
import os
import struct
import subprocess
import sys
import time

HOST_BIN = sys.argv[1] if len(sys.argv) > 1 else ".build/debug/ScreenRecordHost"


def send(proc, obj):
    payload = json.dumps(obj).encode("utf-8")
    proc.stdin.write(struct.pack("<I", len(payload)))
    proc.stdin.write(payload)
    proc.stdin.flush()


def recv(proc):
    header = proc.stdout.read(4)
    if not header or len(header) < 4:
        return None
    n = struct.unpack("<I", header)[0]
    body = proc.stdout.read(n)
    return json.loads(body)


def main():
    env = dict(os.environ, SCREENRECORDHOST_NO_APPKIT="1")
    proc = subprocess.Popen(
        [HOST_BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env
    )
    failures = []

    # 1. Chrome 握手
    send(proc, {"type": "connect"})
    resp = recv(proc)
    if resp != {"type": "connect"}:
        failures.append(f"connect handshake: got {resp}")

    # 2. ping
    send(proc, {"cmd": "ping"})
    resp = recv(proc)
    if not (resp and resp.get("ok") and resp.get("version")):
        failures.append(f"ping: got {resp}")

    # 3. status
    send(proc, {"cmd": "status"})
    resp = recv(proc)
    if not (resp and resp.get("ok") and resp.get("recording") is False):
        failures.append(f"status: got {resp}")

    # 4. list-recordings(骨架期返回空列表)
    send(proc, {"cmd": "list-recordings"})
    resp = recv(proc)
    if not (resp and resp.get("ok") and isinstance(resp.get("items"), list)):
        failures.append(f"list-recordings: got {resp}")

    # 5. start-record:有权限则真实录 2 秒并验证产出文件;无权限则断言明确错误
    send(proc, {"cmd": "start-record"})
    resp = recv(proc)
    if resp and resp.get("ok"):
        time.sleep(2.0)
        send(proc, {"cmd": "stop-record"})
        resp2 = recv(proc)
        if not (resp2 and resp2.get("ok") and resp2.get("file")):
            failures.append(f"stop after start: got {resp2}")
        else:
            fpath = os.path.expanduser("~/Movies/ScreenRecord") + "/" + resp2["file"]
            if not os.path.exists(fpath) or os.path.getsize(fpath) < 10_000:
                failures.append(f"recorded file missing/tiny: {fpath}")
    elif resp and resp.get("ok") is False:
        if "permission" not in str(resp.get("error", "")):
            failures.append(f"start-record error not permission-related: {resp}")
        print("  note: screen recording permission not granted; start-record rejected as expected")
    else:
        failures.append(f"start-record: got {resp}")

    # 6. capture-screen:有权限则截图并验证 PNG 产出;无权限则断言明确错误
    send(proc, {"cmd": "capture-screen"})
    resp = recv(proc)
    if resp and resp.get("ok"):
        fpath = resp.get("path", "")
        if not fpath or not os.path.exists(fpath) or os.path.getsize(fpath) < 1_000:
            failures.append(f"capture-screen file invalid: {resp}")
    elif resp and resp.get("ok") is False:
        if "permission" not in str(resp.get("error", "")):
            failures.append(f"capture-screen error not permission-related: {resp}")
    else:
        failures.append(f"capture-screen: got {resp}")

    # 7. reveal-in-finder:不存在的路径应返回 ok=false
    send(proc, {"cmd": "reveal-in-finder", "path": "/nonexistent/file.mp4"})
    resp = recv(proc)
    if not (resp and resp.get("ok") is False):
        failures.append(f"reveal-in-finder: got {resp}")

    # 8. read-file:越权路径与非法参数必须拒绝
    send(proc, {"cmd": "read-file", "path": "/etc/passwd", "offset": 0, "size": 100})
    resp = recv(proc)
    if not (resp and resp.get("ok") is False):
        failures.append(f"read-file path escape: got {resp}")
    send(proc, {"cmd": "read-file", "path": "/tmp/x.png", "offset": 0, "size": 99999999})
    resp = recv(proc)
    if not (resp and resp.get("ok") is False):
        failures.append(f"read-file bad size: got {resp}")
    send(proc, {"cmd": "read-file", "path": "/tmp/x.png", "offset": -5, "size": 100})
    resp = recv(proc)
    if not (resp and resp.get("ok") is False):
        failures.append(f"read-file negative offset: got {resp}")

    # 9. test-bitrate:码率档位自测(分辨率+帧率组合,防回归)
    send(proc, {"cmd": "test-bitrate"})
    resp = recv(proc)
    if resp and resp.get("ok"):
        got = {(item["height"], item["fps"]): item["bitrate"] for item in resp.get("items", [])}
        expected = {
            (2160, 60): 36_000_000,
            (2160, 30): 24_000_000,
            (1440, 60): 24_000_000,
            (1080, 60): 18_000_000,
            (1080, 30): 12_000_000,
            (720, 30): 8_000_000,
        }
        if got != expected:
            failures.append(f"test-bitrate mismatch: {got} != {expected}")
    else:
        failures.append(f"test-bitrate: got {resp}")

    # 10. test-mixer:音频混合逻辑自测(无需屏幕权限)
    send(proc, {"cmd": "test-mixer"})
    resp = recv(proc)
    if not (resp and resp.get("ok")):
        failures.append(f"test-mixer: got {resp}")

    # 11. 未知命令
    send(proc, {"cmd": "bogus"})
    resp = recv(proc)
    if not (resp and resp.get("ok") is False):
        failures.append(f"unknown cmd: got {resp}")

    # 12. 缺 cmd 字段
    send(proc, {"hello": "world"})
    resp = recv(proc)
    if not (resp and resp.get("ok") is False):
        failures.append(f"missing cmd: got {resp}")

    proc.stdin.close()
    proc.terminate()
    proc.wait(timeout=5)

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("PASS: protocol smoke test (12 checks)")


if __name__ == "__main__":
    main()

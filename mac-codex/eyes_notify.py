#!/usr/bin/env python3
"""codex notify 脚本：agent-turn-complete 时让背屏微笑。

在 ~/.codex/config.toml 顶部加（不要放在 [table] 之后）：
  notify = ["python3", "/Users/YOU/.codex/eyes_notify.py"]
"""
import json
import os
import sys
import urllib.parse
import urllib.request

CONF = os.path.expanduser("~/.codex/eyes.conf")


def load_conf():
    d = {}
    if os.path.exists(CONF):
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    d[k.strip()] = v.strip()
    return d


def push(state):
    c = load_conf()
    ip = c.get("PHONE_IP")
    if not ip:
        return
    port = c.get("PORT", "8788")
    url = f"http://{ip}:{port}/set?e={urllib.parse.quote(state)}"
    try:
        urllib.request.urlopen(url, timeout=1.5).read()
    except Exception:
        pass  # 手机不在网内时静默失败，不影响 codex


def main():
    try:
        event = json.loads(sys.argv[-1])
    except Exception:
        event = {}
    if event.get("type") == "agent-turn-complete":
        push("DONE")


if __name__ == "__main__":
    main()

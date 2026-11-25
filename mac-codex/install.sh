#!/bin/bash
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SRC" <<'PY'
import json, os, plistlib, re, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path

source = Path(sys.argv[1])
codex = Path.home() / ".codex"
bindir = Path.home() / ".local/bin"
hooks_path = codex / "hooks.json"
codex.mkdir(parents=True, exist_ok=True)
bindir.mkdir(parents=True, exist_ok=True)
data = json.loads(hooks_path.read_text()) if hooks_path.exists() else {}
hooks = data.setdefault("hooks", {})
eyes = shlex.quote(str(bindir / "eyes"))
for event, state in (("UserPromptSubmit", "THINKING"), ("PermissionRequest", "QUESTION"),
                     ("PostToolUse", "THINKING"), ("Stop", "DONE")):
    groups = hooks.setdefault(event, [])
    for group in groups:
        group["hooks"] = [
            hook for hook in group.get("hooks", [])
            if not re.fullmatch(r'''(?:'[^']*/eyes'|[^ ;]*/eyes) (?:--quiet )?(?:THINKING|QUESTION|DONE|usage)(?:; echo '\{\}'| \|\| true)?''',
                                hook.get("command", ""))
        ]
    groups[:] = [group for group in groups if group["hooks"]]
    groups.append({"hooks": [{"type": "command", "command": f"{eyes} --quiet {state} || true", "timeout": 8}]})
    if event == "Stop":
        groups[-1]["hooks"].append({
            "type": "command", "command": f"{eyes} --quiet usage || true",
            "timeout": 20, "async": True,
        })

for command in ("eyes", "cx"):
    target = bindir / command
    with tempfile.NamedTemporaryFile(dir=bindir, delete=False) as file:
        temporary = Path(file.name)
    shutil.copyfile(source / command, temporary)
    temporary.chmod(0o755)
    temporary.replace(target)
contents = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
if not hooks_path.exists() or hooks_path.read_text() != contents:
    if hooks_path.exists():
        shutil.copy2(hooks_path, hooks_path.with_suffix(".json.reareyes.bak"))
    with tempfile.NamedTemporaryFile(mode="w", dir=codex, delete=False) as file:
        file.write(contents)
    Path(file.name).replace(hooks_path)
agents = Path.home() / "Library/LaunchAgents"
agents.mkdir(parents=True, exist_ok=True)
label = "com.reareyes.codex-sync"
agent = agents / f"{label}.plist"
with tempfile.NamedTemporaryFile(dir=agents, delete=False) as file:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": [sys.executable, str(bindir / "eyes"), "watch"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 5,
        "EnvironmentVariables": {
            "PATH": os.environ.get("PATH", os.defpath),
            "CODEX_HOME": os.environ.get("CODEX_HOME", str(codex)),
            **({"ANDROID_SERIAL": os.environ["ANDROID_SERIAL"]} if os.environ.get("ANDROID_SERIAL") else {}),
        },
    }, file)
Path(file.name).replace(agent)
domain = f"gui/{os.getuid()}"
subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], capture_output=True)
subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
print("Mac 同步服务已启动。用 USB 或无线调试连接手机，打开 Robot Eyes 并点击「同步 Codex」。")
PY

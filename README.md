# Robot Eyes · 小米 17 Pro Max 背屏电子眼

让手机背屏显示 Codex 和其他已接入 Agent 的工作状态。手机端用 Kotlin 绘制动画，Mac 通过已授权的 USB 或无线 ADB 连接发送状态。

## Flutter 移动端

[mobile](mobile/README.md) 共用 Android、iOS 和 Web 的首页、配对和消息界面。Android 背屏、校准和原生电子眼复用现有 Kotlin 代码。iPhone 可使用 Tailscale 内的 Web App，并从 Safari 添加到主屏幕。

## Tailscale 远程连接

Robot Eyes 桌面端位于 [desktop](desktop/README.md)，共用 Flutter 和 Dart 代码，提供 macOS 与 Windows 工程。电脑和安卓手机加入同一 tailnet 后，手机在使用移动数据时也可以查看 Codex 状态和用量。

1. 启动桌面端。服务自动绑定电脑本机的 `127.0.0.1:18792`。
2. 在电脑终端运行 `tailscale serve --bg --https=8443 18792`。如果 Tailscale 提示启用 HTTPS，按提示完成设置。8443 需空闲。
3. 安装新版 Android 应用后，用 USB 连接电脑并授权调试。桌面端会把配对配置自动传到手机。也可以点击桌面端「复制配对配置」，手动粘贴到手机「远程连接」并保存。
4. 在手机打开「远程连接」，可以查看电脑状态和最近同步时间。

两端保持 Tailscale 在线，电脑需保持唤醒，桌面端可最小化。安卓端在应用可见时刷新远程状态，包含背屏和主屏横屏模式。

## 自动选择同步连接

手机主页面的「连接状态」分别显示 USB、局域网和 Tailscale。收到状态数据后才会标为已连接，当前使用的连接显示为「同步中」。多条路径可用时，优先使用 USB，其次是局域网，再切换到 Tailscale。点击「同步 Codex」会等待当前可用连接的下一次状态更新。

- **USB**：电脑安装 ADB，手机开启 USB 调试并授权，启动新版 Flutter 桌面端。已授权的无线 ADB 会显示为局域网。
- **局域网**：手机和电脑连同一可信网络。手机开启「局域网 MCP」后，用 USB 连接电脑并授权调试，桌面端会自动导入手机配置，拔线后继续同步。也可以从手机复制配置，粘贴到桌面端「手机局域网 → 管理配置」。手机内网 IP 变化时重新插线或复制配置。
- **Tailscale**：按上节完成配对。外出时，手机通过 Tailscale 获取状态。

## 首次安装

Mac 需要 ADB 和 Python 3。手机打开 USB 调试，插线后授权这台 Mac，再执行：

```sh
(cd mobile && flutter build apk --debug)
adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
./mac-codex/install.sh
~/.local/bin/eyes connect
```

安装脚本会启动 Mac 后台同步，并备份和合并现有的 Codex hooks。后台同步从本地会话读取任务状态和用量。使用审批提醒时，在 Codex 中用 `/hooks` 检查并信任 Robot Eyes 的命令。如果此前设置了指向 `eyes_notify.py` 的旧版 `notify`，可以移除那条配置，避免重复发送完成状态。

Codex 弹出用户选择时，背屏会显示疑问表情，等 Codex 收到答复并继续工作再切回运行中。

## 局域网 MCP

如果 AI 工具和 Robot Eyes 桌面端运行在同一台电脑，在「桌面 AI MCP」点「复制给 AI 配置」，再将内容粘贴到 AI 对话，让它安装状态上报 Skill 并配置 MCP。手机主屏「AI 工具状态」会按名称显示已接入的工具。具体步骤见[桌面端说明](desktop/README.md#桌面-ai-mcp)。

1. 用下文的 Gradle 命令构建并安装 `reareyes/app/build/outputs/apk/debug/app-debug.apk`。历史 APK 不包含此功能。
2. 让手机和电脑连接同一个可信局域网。在手机主屏打开「局域网 MCP」，点「开启 MCP」和「复制配置」。通过可信的方式把配置转到电脑。
3. 在桌面工具的 MCP 设置中添加 `robot-eyes`，传输选 **Streamable HTTP**。使用配置中的 `url` 和 `Authorization: Bearer <访问密钥>` 请求头。支持 `mcpServers` JSON 的客户端可以粘贴配置，具体字段以客户端为准。
4. 让 Agent 调用 `set_eye_state`，例如传入 `{"agent":"WorkBuddy","state":"THINKING"}`。开启手机背屏显示后即可看到汇总状态。

可以把这段指令加到 Agent 的规则或任务提示中，让它主动更新状态。

> 开始或恢复任务时调用 `robot-eyes` 的 `set_eye_state` 上报 `THINKING`，阻塞等待我确认时上报 `QUESTION`，完成时上报 `DONE`，失败时上报 `ERROR`。每次使用固定的 Agent 名称，同一任务使用同一个 `session`。

同名 Agent 并行时传入不同的 `session`。背屏优先显示等待确认、运行中、失败、完成。`IDLE` 或 `SLEEP` 清除该会话，运行和等待状态在 15 分钟未更新后过期，完成和失败保留 30 秒。

MCP 默认关闭，开启后只接收同一 Wi-Fi 或以太网 IPv4 子网的请求，并要求访问密钥。手机地址如果变化，重新打开「局域网 MCP」复制新地址。该接口使用局域网 HTTP，应在可信网络使用。已有的 ADB 同步和 Codex 用量走原来的本机接口。

Codex CLI 可以在启动它的环境设置 `REAREYES_MCP_TOKEN`，再执行 `codex mcp add robot-eyes --url 'http://手机IP:8789/mcp' --bearer-token-env-var REAREYES_MCP_TOKEN`。

只支持本地 stdio MCP 的桌面客户端可通过项目里的 Python 3 转接脚本连接。配置中的脚本路径需替换成电脑上的绝对路径，URL 和密钥从 App 里复制。

```json
{
  "mcpServers": {
    "robot-eyes": {
      "command": "python3",
      "args": ["/absolute/path/to/mac-codex/mcp-stdio.py"],
      "env": {
        "REAREYES_MCP_URL": "http://192.168.1.20:8789/mcp",
        "REAREYES_MCP_TOKEN": "填入 Bearer 后面的访问密钥"
      }
    }
  }
}
```

WorkBuddy、Xiaomi MiMo、DeepSeek 等工具能否接入，取决于具体桌面客户端是否支持上述任一 MCP 传输，以及调用是否在能访问手机地址的电脑上执行。MCP 连接本身不会订阅工具的内部任务事件，状态由 Agent 或其 Hooks 调用上报。

## 通过 Mac Hooks 接入其他 Agent

已有安装只需重新运行 `./mac-codex/install.sh` 更新 Mac 同步服务。在其他 Agent 的 Hooks 设置中，把下表里的 `my-agent` 换成自定义名称，并为工具支持的事件填入对应命令。

| Agent 事件 | Hook 命令 |
|---|---|
| 开始任务、恢复执行或工具执行完成 | `~/.local/bin/eyes --quiet agent my-agent THINKING` |
| 等待用户确认 | `~/.local/bin/eyes --quiet agent my-agent QUESTION` |
| 任务完成 | `~/.local/bin/eyes --quiet agent my-agent DONE` |
| 任务失败 | `~/.local/bin/eyes --quiet agent my-agent ERROR` |
| 取消任务或清除状态 | `~/.local/bin/eyes --quiet agent my-agent IDLE` |

同一个 Agent 并行运行多个会话时，可以在状态后追加工具提供的会话 ID，确保各会话独立更新。可以先在终端运行一条命令测试，后台服务通常在 2 秒内同步。长任务可以用工具执行完成事件刷新运行状态。连续 15 分钟没有更新的运行或等待状态会自动清除，完成和失败状态保留 30 秒。

背屏显示汇总表情，按等待确认、运行中、失败、完成的顺序取优先级最高的状态。用量环显示 Codex 用量。

## 手机操作

把手机横放在支架上时，在控制页点「主屏横屏显示」进入全屏。画面会随手机在两个横向之间翻转，前台保持常亮。Flutter 大屏模式中，眼睛铺满画面底层，状态标签在左侧纵向对齐，运行中的加载点在底部中央。双击显示左上角的用量和右下角的退出按钮，再双击隐藏，也会在 15 秒后自动隐藏。主屏全屏和背屏共用任务状态、表情动画及轻点、长按跟视、拖动、休眠唤醒手势。点右下角「退出全屏」或使用系统返回，即可回到控制页继续设置 MCP、同步 Codex、调整自动睡眠和测试表情。

用量和「退出全屏」平时淡显，触碰屏幕后恢复正常亮度，15 秒后再次淡出。再次触碰会重新计时。

在小米 17 Pro Max 上，先在 Shizuku 中启动服务。打开 Robot Eyes 主屏页面，点击「显示到背屏」打开动画，或点击「圆环校准」打开背屏校准。首次使用需要在 Shizuku 弹窗中允许 Robot Eyes。校准时在背屏分别选上镜头和下镜头，调整位置和大小后点「保存」。

Shizuku 运行时可以直接从手机操作。用无线调试启动的 Shizuku 需要在手机重启后重新启动。连接装有同步服务的 Mac 后，在手机主屏点「同步 Codex」即可手动刷新表情和用量。后台服务也会在 ADB 已连接时同步状态和用量。

## 同一 Wi-Fi 连接

1. 手机和 Mac 连接同一个 Wi-Fi。在手机开发者选项打开「无线调试」，选择「使用配对码配对设备」。
2. 在 Mac 运行 `adb pair 手机IP:配对端口`，输入手机显示的配对码。配对完成后运行 `adb devices` 确认设备已连接。
3. 如果已配对但未自动连接，运行 `adb connect 手机IP:连接端口`。连接端口显示在「无线调试」主页面，配对端口显示在配对弹窗里。
4. 拔掉 USB，打开 Robot Eyes，点「同步 Codex」。

## Mac 操作

解锁手机，通过 USB 或无线调试连接 Mac，运行 `~/.local/bin/eyes connect`。它会自动选择设备、建立端口转发，并把动画界面移到背屏。ADB 连接已建立时，无需在 Robot Eyes 里输入 IP 或端口。如果电脑上同时连接了多台 Android 设备，用 `ANDROID_SERIAL` 指定手机。

| 命令 | 用途 |
|---|---|
| `eyes connect` | 打开背屏动画 |
| `eyes front` | 打开 Robot Eyes 主屏，查看预览和日志 |
| `eyes calibrate` | 打开背屏校准，分别调整上下圆环的圆心和大小 |
| `eyes usage` | 手动同步 Codex 的 5 小时和周用量 |
| `eyes status` | 查看当前表情 |
| `eyes QUESTION` | 手动测试等待批准的表情 |

如果 `eyes` 不在 PATH 中，可使用 `~/.local/bin/eyes`。普通 `codex` 会话通过 hooks 更新表情。使用 `cx` 启动命令行会话时，还会把异常退出显示为 X 眼。

| 事件 | 表情 |
|---|---|
| 提交提示或工具执行结束 | THINKING |
| 等待批准 | QUESTION |
| 停止生成 | DONE |
| `cx` 异常退出 | ERROR |
| 完成或出错 30 秒后，或初始空闲 90 秒后 | SLEEP |

待机时两眼会跟随瞳光偶尔转向，并随机眨一到两下。待机时也会短暂微笑、眨单眼或露出惊讶脸，随后恢复普通表情。这些小动作不影响自动睡眠计时。工作中的瞳光会左右扫读，随后看向斜上方，想到点子时会瞪大眼睛并亮起感叹号，再继续扫读。疑问态会保留高低眼，等待批准时保留该表情。任务完成时，双眼会先睁大，再轻轻摆头收成月牙。睡眠时偶尔歪头。

轻点时，瞳光先看向触点。点中间会让两眼靠近，点单侧会让近侧眼睛微眯，点边缘时还会轻轻歪头。背屏会从触点散出青紫色粒子，电子眼偶尔眨单眼，约一秒内回到当前状态。拖动时瞳光先跟手，眼形稍后跟上，快速移动时瞳光会略微越过指尖，松手后轻轻回弹。长按停住约 1.5 秒会短暂露出疑问脸。触摸期间，状态标签实时更新，电子眼在动作结束后过渡到最新状态。

主屏「自动睡眠」可设置待机多久后睡眠，默认 90 秒。轻点睡着的眼睛时，靠近触点的一只眼先压平闭眼弧线，再慢慢睁开一条缝，保持 0.5 秒，露出一部分瞳孔，再闭眼停 0.2 秒，随后双眼睁开、看向前方并进入待机。睡满 5 分钟后，第一次轻点只播放单眼半睁和闭眼，4 秒内再次轻点才会唤醒。背屏上的快速双击只处理第一下，深度休眠时请稍停后再轻点。

背屏切换在小米 17 Pro Max（2509FPN0BC）上通过 Shizuku 或 ADB 移动应用任务完成。系统收回背屏后，解锁手机并从主屏点「显示到背屏」，也可以重新运行 `eyes connect`。动画全屏显示时会请求背屏常亮，系统仍可在锁屏时关闭面板。ADB 同步接口监听手机本机，局域网 MCP 使用独立端口。

背屏靠摄像头的一侧显示用量环，上方对应 5 小时窗口，下方对应周窗口。数字与圆弧表示剩余比例。连接桌面服务时，只显示服务返回的有效用量窗口。圆环校准时仍显示圆环边界。

## 构建原生 Android 版本

使用 JDK 17 和 Gradle 8.10.2，并通过 `ANDROID_HOME` 指定 Android SDK。

```sh
cd reareyes
JAVA_HOME=$(/usr/libexec/java_home -v 17) gradle assembleDebug --no-daemon
```

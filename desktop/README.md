# Robot Eyes 桌面端

Flutter 桌面应用和 Dart HTTP 服务。macOS 与 Windows 使用同一套状态查询和收件箱接口。

## 开发运行

在 Flutter Manager 导入本目录，选择 macOS 或 Windows 设备运行。终端也可以从本目录运行 `flutter pub get`，再使用 `flutter run -d macos` 或 `flutter run -d windows`。Windows 的原生构建需在 Windows 环境执行。

应用启动时会监听 `127.0.0.1:18792`。最小化或关闭主窗口时，服务继续在后台运行。点击 macOS 菜单栏或 Windows 通知区域的眼睛图标，可以查看服务状态、启动或停止服务、复制手机配对或桌面 MCP 配置，以及重新打开主窗口。「退出」会关闭应用和服务。需要登录后自动启动时，可将应用加入 macOS 登录项或 Windows 启动应用。

## 配对

1. 电脑加入 Tailscale，并在终端运行 `tailscale serve --bg --https=8443 18792`。
2. 用 USB 连接安卓手机并授权调试。桌面端会检测已配置的 Serve 地址并自动更新手机上的远程配对。
3. 手机加入同一 tailnet。手动配对时，在桌面端点「重新检测」和「复制配对配置」，再粘贴到手机的「远程连接」。请把配对配置当作密码保管。
4. 如需关闭此转发，在电脑运行 `tailscale serve --https=8443 off`。

## USB 和局域网

- 安装 Android SDK Platform Tools 并授权 USB 调试后，桌面端自动检测连接并发送状态。多台手机同时连接时，可通过 `ANDROID_SERIAL` 指定设备。
- 在手机开启「局域网 MCP」，通过 USB 连接电脑并授权调试。桌面端会自动导入手机的局域网配置。拔线后，手机和电脑处于同一可信子网即可继续同步。手机 IP 变化时可重新插线刷新，或在手机复制配置并粘贴到桌面端「手机局域网 → 管理配置」。

## 桌面 AI MCP

- 在「桌面 AI MCP」选择 WorkBuddy、OpenCode、OpenClaw 或通用格式，复制配置并合并到相应工具的 MCP 设置，再启用连接器。地址是 `http://127.0.0.1:18793/mcp`，传输选择 Streamable HTTP，使用配置自带的 `Authorization` 请求头。OpenCode 示例适用于使用 `mcp.servers` 的版本。
- 桌面「AI 工具连接」按名称合并已初始化的本机 MCP 会话，显示会话数和最近通信时间。客户端主动关闭会话，或连续 2 小时没有请求时，会从列表移除。
- 手机主屏「AI 工具状态」按名称显示已接入的工具。专用配置会带上工具名称，通用配置使用 MCP 客户端申报的名称。USB、局域网和 Tailscale 都会同步这个列表。
- 连接后工具显示待机。要随任务切换状态，点击「复制上报规则」并将指令加入 AI 工具的规则。停掉任务后如果工具未发送状态，Robot Eyes 无法从 MCP 连接推断停止原因。集成时请从工具的停止或失败事件调用上报，将状态保持约 30 秒。

> 任务开始或恢复时调用 Robot Eyes 的 `set_eye_state`，传入 `state: "THINKING"`。等待确认时用 `QUESTION`，完成时用 `DONE`，失败退出时用 `ERROR`，手动取消时用 `STOPPED`。同一个任务的开始、等待、完成、停止和失败应使用同一个 `session`。并行任务请分别使用稳定的 `session`。结束单个任务的展示可传入 `IDLE`。

## Codex 用量和消息

- 两端均读取当前用户的 Codex 会话事件和有效用量窗口，默认目录为 `~/.codex/sessions`（Windows 为 `%USERPROFILE%\.codex\sessions`），支持 `CODEX_HOME`。用量随 Codex 写入会话日志更新。
- macOS 同时读取通过现有 `eyes agent` 注册的 Agent 状态。macOS 桌面包用于直接安装，以便访问同一用户的 Codex 会话目录。
- 配对密钥和手机消息保存在 macOS 的 `~/Library/Application Support/Robot Eyes` 或 Windows 的 `%LOCALAPPDATA%\Robot Eyes`。已有旧版数据目录时会继续使用原目录。桌面端收到消息后会提示，系统级通知取决于系统权限与免打扰设置。

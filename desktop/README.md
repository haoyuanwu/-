# Robot Eyes 桌面端

Flutter 桌面应用和 Dart HTTP 服务。macOS 与 Windows 使用同一套状态查询和收件箱接口。

## 开发运行

在 Flutter Manager 导入本目录，选择 macOS 或 Windows 设备运行。终端也可以从本目录运行 `flutter pub get`，再使用 `flutter run -d macos` 或 `flutter run -d windows`。Windows 的原生构建需在 Windows 环境执行。

应用启动时会监听 `127.0.0.1:18792`。最小化或关闭主窗口时，服务继续在后台运行。点击 macOS 菜单栏或 Windows 通知区域的眼睛图标，可以查看服务状态、启动或停止服务、复制手机配对或 AI 配置，以及重新打开主窗口。「退出」会关闭应用和服务。需要登录后自动启动时，可将应用加入 macOS 登录项或 Windows 启动应用。

## 配对

1. 在 Windows 或 macOS 上连接 Tailscale。在桌面端「Tailscale 连接」点「重新检测」。若显示「已连接，待配置 Serve」，复制面板里的命令，在 Windows PowerShell 或 macOS 终端运行，然后重新检测。Windows 的命令可使用 Tailscale 安装路径，无需先把它加入 PATH。
2. 用 USB 连接安卓手机并授权调试。桌面端会检测已配置的 Serve 地址并自动更新手机上的远程配对。
3. 手机加入同一 tailnet。手动配对时，在桌面端点「重新检测」和「复制配对配置」，再粘贴到手机的「远程连接」。请把配对配置当作密码保管。
4. 如需关闭此转发，在电脑运行 `tailscale serve --https=8443 off`。

## USB 和局域网

- 安装 Android SDK Platform Tools 并授权 USB 调试后，桌面端自动检测连接并发送状态。多台手机同时连接时，可通过 `ANDROID_SERIAL` 指定设备。
- 在手机开启「局域网 MCP」，通过 USB 连接电脑并授权调试。桌面端会自动导入手机的局域网配置。拔线后，手机和电脑处于同一可信子网即可继续同步。手机 IP 变化时可重新插线刷新，或在手机复制配置并粘贴到桌面端「手机局域网 → 管理配置」。

## 桌面 AI MCP

- 在「桌面 AI MCP」点「复制给 AI 配置」，或从 Windows 托盘、macOS 菜单栏的「复制配置」菜单复制。将整段内容粘贴到同一台电脑上的 AI 对话。AI 会按当前客户端格式配置本机 Streamable HTTP MCP，安装 [状态上报 Skill](skills/robot-eyes-reporting/SKILL.md)，并验证 `set_eye_state`。复制内容包含本机访问密钥，请粘贴到你信任的 AI 对话。
- 「查看配置详情」会显示通用 MCP 配置和上报 Skill，访问密钥以掩码显示。「AI 工具连接」按名称合并已初始化的本机 MCP 会话，显示工具名称和当前状态。配置面板会保留本次应用运行期间最近验证的客户端和时间。客户端关闭会话，或连续 2 小时没有请求时，会从连接列表移除。
- 手机主屏「AI 工具状态」按 MCP 客户端申报的名称显示已接入的工具。USB、局域网和 Tailscale 都会同步这个列表。

## Codex 用量和消息

- 两端均读取当前用户的 Codex 会话事件和有效用量窗口，默认目录为 `~/.codex/sessions`（Windows 为 `%USERPROFILE%\.codex\sessions`），支持 `CODEX_HOME`。用量随 Codex 写入会话日志更新。
- macOS 同时读取通过现有 `eyes agent` 注册的 Agent 状态。macOS 桌面包用于直接安装，以便访问同一用户的 Codex 会话目录。
- 配对密钥和手机消息保存在 macOS 的 `~/Library/Application Support/Robot Eyes` 或 Windows 的 `%LOCALAPPDATA%\Robot Eyes`。已有旧版数据目录时会继续使用原目录。桌面端收到消息后会提示，系统级通知取决于系统权限与免打扰设置。

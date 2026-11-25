# Robot Eyes 移动端

同一个 Flutter 项目提供 Android、iOS 和 Web。首页、用量、配对设置、消息界面共用。三端的主屏横屏模式共用 Flutter 表情动画。Android 的背屏、校准和首页预览复用上一级 `reareyes` 的 Kotlin 源码和资源。

## 真机开发

从仓库根目录保留 `mobile` 和 `reareyes` 的相对位置。在 Flutter Manager 导入 `mobile`，选择设备运行。

- Android 沿用 `com.reareyes.app`。同一签名的升级会保留原配对和校准；实体设备上验证背屏需要小米 17 Pro Max 和运行中的 Shizuku。
- iOS 在 Xcode 打开 `ios/Runner.xcworkspace`，为 Runner 选择自己的签名 Team。若要脱离调试器从主屏启动，使用 `flutter run --release -d <设备 ID>`。iPhone 与电脑需加入同一个 Tailscale 网络。

### 换电脑后使用同一 Android 签名

拉取 `main` 后，在 Flutter Manager 导入 `mobile` 并运行 Android，或在 `mobile` 运行 `flutter run`。Gradle 会读取仓库中的 `mobile/android/key.properties` 和 `mobile/android/robot-eyes.jks`。Debug、Profile 和 Release 都使用同一张签名证书，可以覆盖安装到已有相同签名的版本。

## AI 对话与手机提醒

- 使用电脑模型时，请在电脑的「模型连接」设定手机默认模型。手机完成配对后直接点「说话」。如需绕过电脑，在手机首页进入「模型设置」，选择云端、局域网或本机模型，填写 OpenAI 兼容接口和模型 ID。本机模式连接运行在手机回环地址的模型服务。
- 说话时可以看到随麦克风音量变化的反馈。点「结束录音」可以先编辑转写，点「结束并发送」会在识别结束后发送。
- 「语音与提醒」可以分别关闭朗读 AI 回复和开启播报重要提醒。气泡可单独停止当前朗读。
- Android 在「语音与提醒」授权通知访问后，可从二级页面搜索和勾选关注的 App、联系人及关键词。联系人选择页会单独申请通讯录权限。验证码类提醒可主动点开查看系统允许显示的内容。
- iOS 16 及更新版本可在快捷指令中使用「显示 Robot Eyes 提醒」或「切换 Robot Eyes 表情」。签名运行时，给 Runner 和分享扩展选择同一 Team，并在 Apple 开发者账号启用 App Group `group.com.reareyes.rearEyesMobile.interaction`。在系统分享菜单将文字或链接分享给 Robot Eyes 后，回到 App 查看气泡。实况活动需要 iOS 16.2 或更高版本。

## Web App

在本目录运行 `flutter build web --no-web-resources-cdn`。把 `build/web` 的内容放在运行桌面端的用户数据目录下的 `web` 子目录。

- macOS 目录为 `~/Library/Application Support/Robot Eyes/web`。
- Windows 目录为 `%LOCALAPPDATA%\Robot Eyes\web`。
- 已有旧版数据目录时，Web 文件继续放在原目录的 `web` 子目录。

在 iPhone 的 Safari 打开桌面端显示的 Tailscale HTTPS 地址，再到「远程连接」粘贴桌面端复制的配对配置。Safari 可用「添加到主屏幕」把页面作为 Web App 打开。浏览器和从主屏启动的 Web App 可能使用不同存储，首次从主屏启动时若显示「未配对」，粘贴一次配对配置即可。

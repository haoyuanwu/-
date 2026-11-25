# Robot Eyes 移动端

同一个 Flutter 项目提供 Android、iOS 和 Web。首页、用量、配对设置、消息界面共用。三端的主屏横屏模式共用 Flutter 表情动画。Android 的背屏、校准和首页预览复用上一级 `reareyes` 的 Kotlin 源码和资源。

## 真机开发

从仓库根目录保留 `mobile` 和 `reareyes` 的相对位置。在 Flutter Manager 导入 `mobile`，选择设备运行。

- Android 沿用 `com.reareyes.app`。同一签名的升级会保留原配对和校准；实体设备上验证背屏需要小米 17 Pro Max 和运行中的 Shizuku。
- iOS 在 Xcode 打开 `ios/Runner.xcworkspace`，为 Runner 选择自己的签名 Team。若要脱离调试器从主屏启动，使用 `flutter run --release -d <设备 ID>`。iPhone 与电脑需加入同一个 Tailscale 网络。

## Web App

在本目录运行 `flutter build web --no-web-resources-cdn`。把 `build/web` 的内容放在运行桌面端的用户数据目录下的 `web` 子目录。

- macOS 目录为 `~/Library/Application Support/Robot Eyes/web`。
- Windows 目录为 `%LOCALAPPDATA%\Robot Eyes\web`。
- 已有旧版数据目录时，Web 文件继续放在原目录的 `web` 子目录。

在 iPhone 的 Safari 打开桌面端显示的 Tailscale HTTPS 地址，再到「远程连接」粘贴桌面端复制的配对配置。Safari 可用「添加到主屏幕」把页面作为 Web App 打开。浏览器和从主屏启动的 Web App 可能使用不同存储，首次从主屏启动时若显示「未配对」，粘贴一次配对配置即可。

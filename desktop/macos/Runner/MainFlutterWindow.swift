import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate, NSPopoverDelegate {
  private var channel: FlutterMethodChannel!
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private let statusLabels = (0..<5).map { _ in NSTextField(labelWithString: "") }
  private lazy var toggleButton = NSButton(
    title: "启动服务", target: self, action: #selector(toggleService)
  )
  private let copyMenu = NSPopUpButton(frame: .zero, pullsDown: true)
  private let copyFeedback = NSTextField(labelWithString: "")
  private var copyFeedbackTask: DispatchWorkItem?
  private var lastMouseDown: NSEvent?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = frame
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    appearance = NSAppearance(named: .darkAqua)
    contentMinSize = NSSize(width: 520, height: 420)
    contentViewController = flutterViewController
    setFrame(windowFrame, display: true)
    delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)
    channel = FlutterMethodChannel(
      name: "com.reareyes/desktop",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "messageReceived":
        self.notifyMessage()
      case "updateTray":
        if let snapshot = call.arguments as? [String: Any] {
          self.updateTray(snapshot)
        }
      case "dragWindow":
        if let event = self.lastMouseDown, NSEvent.pressedMouseButtons & 1 != 0 {
          self.performDrag(with: event)
        }
      case "maximizeWindow":
        self.zoom(nil)
      case "minimizeWindow":
        self.miniaturize(nil)
      case "hideWindow":
        self.orderOut(nil)
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    setupTray()
    super.awakeFromNib()
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown { lastMouseDown = event }
    if event.type == .leftMouseUp { lastMouseDown = nil }
    super.sendEvent(event)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    orderOut(nil)
    return false
  }

  private func setupTray() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Robot Eyes")
      button.image?.isTemplate = true
      button.toolTip = "Robot Eyes"
      button.target = self
      button.action = #selector(showTray)
    }

    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 269))
    controller.view.wantsLayer = true
    controller.view.layer?.backgroundColor = NSColor(
      srgbRed: 23.0 / 255, green: 30.0 / 255, blue: 40.0 / 255, alpha: 1
    ).cgColor
    controller.view.layer?.cornerRadius = 12

    let title = NSTextField(labelWithString: "Robot Eyes")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    let open = NSButton(title: "打开主窗口", target: self, action: #selector(openDashboard))
    let quit = NSButton(title: "退出", target: self, action: #selector(quitApplication))
    let actions = NSStackView(views: [toggleButton, open, quit])
    actions.spacing = 8
    copyMenu.addItem(withTitle: "复制配置")
    copyMenu.menu?.autoenablesItems = false
    for (name, key) in [
      ("手机配对配置", "pairing"),
      ("复制给 AI 配置", "aiSetup")
    ] {
      let item = NSMenuItem(title: name, action: #selector(copyConfiguration(_:)), keyEquivalent: "")
      item.representedObject = key
      item.target = self
      copyMenu.menu?.addItem(item)
    }
    copyFeedback.textColor = .secondaryLabelColor
    let copyActions = NSStackView(views: [copyMenu, copyFeedback])
    copyActions.spacing = 8
    let stack = NSStackView(views: [title] + statusLabels + [actions, copyActions])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    stack.setCustomSpacing(13, after: title)
    stack.setCustomSpacing(15, after: statusLabels[4])
    stack.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 18),
      stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 16),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: controller.view.trailingAnchor, constant: -18)
    ])
    for label in statusLabels {
      label.textColor = .secondaryLabelColor
      label.font = .systemFont(ofSize: 13)
    }
    toggleButton.bezelStyle = .rounded
    toggleButton.keyEquivalent = "\r"
    updateTray(["busy": true, "rows": ["正在读取服务状态…"]])
    popover.appearance = NSAppearance(named: .darkAqua)
    popover.delegate = self
    popover.contentViewController = controller
    popover.contentSize = controller.view.frame.size
    popover.behavior = .transient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func updateTray(_ snapshot: [String: Any]) {
    let rows = snapshot["rows"] as? [String] ?? []
    for (index, label) in statusLabels.enumerated() {
      label.stringValue = rows.indices.contains(index) ? rows[index] : ""
    }
    let running = snapshot["running"] as? Bool ?? false
    let busy = snapshot["busy"] as? Bool ?? false
    toggleButton.title = busy ? "切换中…" : (running ? "停止服务" : "启动服务")
    toggleButton.isEnabled = !busy
    let canCopyPairing = snapshot["canCopyPairing"] as? Bool ?? false
    let canCopyMcp = snapshot["canCopyMcp"] as? Bool ?? false
    copyMenu.isEnabled = canCopyPairing || canCopyMcp
    for item in copyMenu.itemArray {
      if let key = item.representedObject as? String {
        item.isEnabled = key == "pairing" ? canCopyPairing : canCopyMcp
      }
    }
  }

  @objc private func copyConfiguration(_ sender: NSMenuItem) {
    guard let key = sender.representedObject as? String else { return }
    channel.invokeMethod("copyConfiguration", arguments: key) { [weak self] result in
      guard let self = self else { return }
      self.copyFeedback.stringValue = (result as? Bool == true) ? "已复制" : "复制失败"
      self.copyFeedbackTask?.cancel()
      let clear = DispatchWorkItem { [weak self] in self?.copyFeedback.stringValue = "" }
      self.copyFeedbackTask = clear
      DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: clear)
    }
  }

  @objc private func showTray() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = statusItem.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      if !NSApp.isActive {
        if #available(macOS 14.0, *) {
          NSApp.activate()
        } else {
          NSApp.activate(ignoringOtherApps: true)
        }
      }
      focusTray()
    }
  }

  func popoverDidShow(_ notification: Notification) {
    focusTray()
  }

  private func focusTray() {
    guard let window = popover.contentViewController?.view.window else { return }
    if !window.isKeyWindow {
      window.makeKey()
    }
  }

  @objc private func toggleService() {
    channel.invokeMethod("toggleService", arguments: nil)
  }

  @objc func openDashboard() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
  }

  @objc private func quitApplication() {
    NSApp.terminate(nil)
  }

  private func notifyMessage() {
    guard !NSApp.isActive || !isVisible else { return }
    NSApp.requestUserAttention(.informationalRequest)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = "Robot Eyes"
      content.body = "收到一条手机消息"
      content.sound = .default
      center.add(UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil
      )) { _ in }
    }
  }
}

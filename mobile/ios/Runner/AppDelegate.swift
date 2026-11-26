import AVFoundation
import Flutter
import Security
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let interaction = RobotInteraction()
  private let pairingQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.reareyes.mobile",
    kSecAttrAccount as String: "desktop-pairing",
  ]

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RearEyesMobile") else {
      return
    }
    interaction.register(with: registrar.messenger())
    let channel = FlutterMethodChannel(name: "com.reareyes/mobile", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else {
        reply(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "loadPairing":
        self.loadPairing(reply)
      case "savePairing":
        self.savePairing(call.arguments as? String, reply)
      case "sleep":
        if let seconds = call.arguments as? Int, [30, 60, 90, 120, 300, 600].contains(seconds) {
          UserDefaults.standard.set(seconds, forKey: "reareyes.sleepSeconds")
        }
        reply(UserDefaults.standard.object(forKey: "reareyes.sleepSeconds") as? Int ?? 90)
      case "permissionStatus":
        reply([
          "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
          "speech": SFSpeechRecognizer.authorizationStatus() == .authorized,
        ])
      case "openPermission":
        switch call.arguments as? String {
        case "microphone" where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
          AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { reply(nil) } }
        case "speech" where SFSpeechRecognizer.authorizationStatus() == .notDetermined:
          SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { reply(nil) } }
        default:
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
          reply(nil)
        }
      case "keepScreenOn":
        UIApplication.shared.isIdleTimerDisabled = call.arguments as? Bool ?? false
        reply(nil)
      default:
        reply(FlutterMethodNotImplemented)
      }
    }
  }

  private func loadPairing(_ reply: FlutterResult) {
    var query = pairingQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      reply(nil)
    } else if status == errSecSuccess, let data = item as? Data {
      reply(String(data: data, encoding: .utf8))
    } else {
      reply(FlutterError(code: "keychain", message: "无法读取配对配置", details: status))
    }
  }

  private func savePairing(_ value: String?, _ reply: FlutterResult) {
    let query = pairingQuery as CFDictionary
    var status: OSStatus
    if let value {
      let data = Data(value.utf8)
      status = SecItemUpdate(query, [kSecValueData as String: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = pairingQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(item as CFDictionary, nil)
      }
    } else {
      status = SecItemDelete(query)
    }
    if status == errSecSuccess || (value == nil && status == errSecItemNotFound) {
      reply(nil)
    } else {
      reply(FlutterError(code: "keychain", message: "无法保存配对配置", details: status))
    }
  }
}

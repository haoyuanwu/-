import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: SLComposeServiceViewController {
  override func isContentValid() -> Bool {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return false }
    return !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || items.flatMap { $0.attachments ?? [] }.contains {
        $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
          || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
      }
  }

  override func didSelectPost() {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    for type in [UTType.plainText, UTType.url] {
      guard let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(type.identifier)
      }) else { continue }
      provider.loadItem(forTypeIdentifier: type.identifier) { [weak self] value, _ in
        DispatchQueue.main.async {
          guard let self else { return }
          let shared = (value as? String) ?? (value as? URL)?.absoluteString
            ?? (value as? NSAttributedString)?.string ?? ""
          self.finish(with: shared)
        }
      }
      return
    }
    finish(with: "")
  }

  override func configurationItems() -> [Any]! { [] }

  private func finish(with shared: String) {
    let note = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let content = shared.trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = content == note ? [note] : [note, content].filter { !$0.isEmpty }
    let text = String(pieces.joined(separator: "\n\n").prefix(8000))
    guard !text.isEmpty else {
      return showError("没有可分享的文字或链接。")
    }
    do {
      try RobotEvents.enqueue(["type": "share", "text": text, "title": "系统分享"], shared: true)
      extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    } catch {
      showError("无法将内容保存到 Robot Eyes。")
    }
  }

  private func showError(_ message: String) {
    let alert = UIAlertController(title: "Robot Eyes", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "关闭", style: .default) { [weak self] _ in
      self?.cancel()
    })
    present(alert, animated: true)
  }
}

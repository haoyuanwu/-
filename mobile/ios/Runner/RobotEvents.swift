import Foundation

enum RobotEvents {
  static let changed = Notification.Name("RobotEyesInteractionEvent")
  private static let appGroup = "group.com.reareyes.rearEyesMobile.interaction"
  private static let folder = "RobotEyesInteractionEvents"

  static func enqueue(_ event: [String: Any], shared: Bool = false) throws {
    guard let location = directory(shared: shared) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let files = FileManager.default
    try files.createDirectory(at: location, withIntermediateDirectories: true)
    let name = "\(Date().timeIntervalSince1970)-\(UUID().uuidString).json"
    let data = try JSONSerialization.data(withJSONObject: event)
    try data.write(to: location.appendingPathComponent(name), options: .atomic)
    for obsolete in items(at: location).dropLast(24) {
      try? files.removeItem(at: obsolete)
    }
    NotificationCenter.default.post(name: changed, object: nil)
  }

  static func take() -> [[String: Any]] {
    let files = FileManager.default
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let locations = [directory(shared: false), directory(shared: true)].compactMap { $0 }
    return locations.flatMap(items).sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        defer { try? files.removeItem(at: url) }
        guard let properties = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modified = properties.contentModificationDate, modified >= cutoff,
          let size = properties.fileSize, size <= 65536,
          let data = try? Data(contentsOf: url),
          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return event
      }
  }

  private static func directory(shared: Bool) -> URL? {
    let files = FileManager.default
    if shared {
      return files.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
        .appendingPathComponent(folder, isDirectory: true)
    }
    return files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent(folder, isDirectory: true)
  }

  private static func items(at directory: URL) -> [URL] {
    let files = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    return (files ?? []).filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

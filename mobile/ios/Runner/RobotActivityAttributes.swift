import ActivityKit

@available(iOS 16.1, *)
struct RobotActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var label: String
    var title: String
  }
}

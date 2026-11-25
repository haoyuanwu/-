import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RobotEyesWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RobotActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: "eyes")
          .foregroundStyle(.cyan)
        VStack(alignment: .leading, spacing: 4) {
          Text(context.state.label).font(.headline)
          Text(context.state.title).font(.subheadline).lineLimit(1)
        }
        Spacer()
      }
      .padding()
      .activityBackgroundTint(Color(red: 0.05, green: 0.08, blue: 0.15))
      .activitySystemActionForegroundColor(.white)
      .foregroundStyle(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "eyes").foregroundStyle(.cyan)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 4) {
            Text(context.state.label).font(.headline)
            Text(context.state.title).font(.subheadline).lineLimit(1)
          }
        }
      } compactLeading: {
        Image(systemName: "eyes").foregroundStyle(.cyan)
      } compactTrailing: {
        Image(systemName: context.state.label == "AI 等待确认" ? "questionmark" : "ellipsis")
          .accessibilityLabel(context.state.label)
      } minimal: {
        Image(systemName: "eyes").foregroundStyle(.cyan)
      }
    }
  }
}

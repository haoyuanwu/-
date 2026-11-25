import AppIntents

@available(iOS 16.0, *)
struct RobotReminderIntent: AppIntent {
  static let title: LocalizedStringResource = "显示 Robot Eyes 提醒"

  @Parameter(title: "提醒内容")
  var message: String

  static var parameterSummary: some ParameterSummary {
    Summary("显示提醒 \(\.$message)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let text = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
    if !text.isEmpty {
      let verification = text.contains("验证码") || text.localizedCaseInsensitiveContains("verification code")
      try RobotEvents.enqueue([
        "type": "notification", "app": "快捷指令",
        "title": verification ? "收到验证消息" : "快捷指令提醒",
        "text": verification ? "" : text, "verification": verification,
      ])
    }
    return .result()
  }
}

@available(iOS 16.0, *)
enum RobotExpression: String, AppEnum {
  case idle = "IDLE"
  case thinking = "THINKING"
  case question = "QUESTION"
  case done = "DONE"
  case sleep = "SLEEP"
  case hello = "HELLO"
  case idea = "IDEA"

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "表情"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .idle: "待机", .thinking: "思考", .question: "等待确认", .done: "完成",
    .sleep: "休眠", .hello: "打招呼", .idea: "有灵感",
  ]
}

@available(iOS 16.0, *)
struct RobotExpressionIntent: AppIntent {
  static let title: LocalizedStringResource = "切换 Robot Eyes 表情"

  @Parameter(title: "表情")
  var expression: RobotExpression

  static var parameterSummary: some ParameterSummary {
    Summary("切换至 \(\.$expression) 表情")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    try RobotEvents.enqueue(["type": "expression", "expression": expression.rawValue])
    return .result()
  }
}

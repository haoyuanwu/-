import ActivityKit
import AVFoundation
import Flutter
import NaturalLanguage
import Speech
import UIKit

final class RobotInteraction: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
  private let defaults = UserDefaults.standard
  private let engine = AVAudioEngine()
  private let synthesizer = AVSpeechSynthesizer()
  private var sink: FlutterEventSink?
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var captureID: UUID?
  private var tapInstalled = false
  private var stopDeadline: DispatchWorkItem?
  private var lastSpeechLevelAt: TimeInterval = 0
  private var utterance: AVSpeechUtterance?
  private var utteranceID: String?
  private var liveActivityAction: Task<Void, Never>?

  override init() {
    super.init()
    synthesizer.delegate = self
    NotificationCenter.default.addObserver(
      self, selector: #selector(deliverPending), name: RobotEvents.changed, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(deliverPending), name: UIApplication.didBecomeActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(audioInterrupted(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
  }

  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "com.reareyes/interaction", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, reply in
        guard let self else { return reply(FlutterMethodNotImplemented) }
        self.handle(call, reply)
      }
    FlutterEventChannel(name: "com.reareyes/interactionEvents", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, _ reply: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "capabilities":
      var liveActivity = false
      if #available(iOS 16.2, *) {
        liveActivity = ActivityAuthorizationInfo().areActivitiesEnabled
      }
      reply(["speech": true, "notifications": false, "liveActivity": liveActivity])
    case "loadSettings":
      reply(defaults.string(forKey: "reareyes.interactionSettings"))
    case "saveSettings":
      guard let value = call.arguments as? String, value.utf8.count <= 256 * 1024 else {
        return reply(FlutterError(code: "invalid_settings", message: nil, details: nil))
      }
      defaults.set(value, forKey: "reareyes.interactionSettings")
      reply(nil)
    case "pendingEvents":
      reply(RobotEvents.take())
    case "startListening":
      startListening(reply)
    case "stopListening":
      stopListening()
      reply(nil)
    case "cancelListening":
      clearRecognition()
      reply(nil)
    case "speak":
      guard let text = arguments?["text"] as? String, !text.isEmpty else {
        return reply(FlutterError(code: "invalid_speech", message: nil, details: nil))
      }
      speak(text, id: arguments?["id"] as? String, reply)
    case "stopSpeaking":
      stopSpeaking()
      reply(nil)
    case "updateLiveActivity":
      guard let state = arguments?["state"] as? String else {
        return reply(FlutterError(code: "invalid_activity", message: nil, details: nil))
      }
      updateLiveActivity(state: state, title: arguments?["title"] as? String, reply: reply)
    case "endLiveActivity":
      finishLiveActivity(reply)
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError? {
    sink = events
    deliverPending()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    clearRecognition()
    stopSpeaking()
    return nil
  }

  @objc private func deliverPending() {
    guard let sink else { return }
    for event in RobotEvents.take() { sink(event) }
  }

  @objc private func audioInterrupted(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .began
    else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.captureID != nil {
        self.clearRecognition()
        self.sink?(["type": "speechError", "text": "语音录制已中断。"])
      }
      if self.utterance != nil {
        let id = self.utteranceID
        self.stopSpeaking()
        self.emitSpeechDone(id)
      }
    }
  }

  private func startListening(_ reply: @escaping FlutterResult) {
    clearRecognition()
    stopSpeaking()
    let id = UUID()
    captureID = id
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard self.captureID == id else { return reply(nil) }
        guard status == .authorized else {
          self.clearRecognition()
          return reply(self.speechError("请在系统设置中允许 Robot Eyes 使用语音识别。"))
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard self.captureID == id else { return reply(nil) }
            guard granted else {
              self.clearRecognition()
              return reply(self.speechError("请在系统设置中允许 Robot Eyes 使用麦克风。"))
            }
            do {
              try self.beginCapture(id)
              reply(nil)
            } catch {
              self.clearRecognition()
              reply(self.speechError("暂时无法开始录音，请稍后重试。"))
            }
          }
        }
      }
    }
  }

  private func beginCapture(_ id: UUID) throws {
    guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
      throw NSError(domain: "RobotEyesSpeech", code: 1)
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement)
    try session.setActive(true)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "RobotEyesSpeech", code: 2)
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    self.recognizer = recognizer
    recognitionRequest = request
    lastSpeechLevelAt = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
      var energy: Float = 0
      let count = Int(buffer.frameLength)
      for index in 0..<count { energy += channel[index] * channel[index] }
      let rms = sqrt(energy / Float(count))
      let level = Double(min(max(rms * 6, 0), 1))
      DispatchQueue.main.async {
        guard let self, self.captureID == id else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - self.lastSpeechLevelAt >= 0.065 else { return }
        self.lastSpeechLevelAt = now
        self.sink?(["type": "speechLevel", "level": level])
      }
    }
    tapInstalled = true
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self, self.captureID == id else { return }
        if let result {
          self.sink?([
            "type": "speech", "text": result.bestTranscription.formattedString,
            "final": result.isFinal,
          ])
        }
        if result?.isFinal == true || error != nil {
          let wasStopping = self.stopDeadline != nil
          self.clearRecognition()
          if error != nil && !wasStopping {
            self.sink?(["type": "speechError", "text": "未能完成语音识别。"])
          } else {
            self.sink?(["type": "speechEnd"])
          }
        }
      }
    }
    engine.prepare()
    try engine.start()
  }

  private func stopListening() {
    guard let id = captureID else { return }
    guard let request = recognitionRequest else {
      clearRecognition()
      sink?(["type": "speechEnd"])
      return
    }
    guard stopDeadline == nil else { return }
    stopCapture()
    request.endAudio()
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.captureID == id else { return }
      self.clearRecognition()
      self.sink?(["type": "speechEnd"])
    }
    stopDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
  }

  private func stopCapture() {
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
  }

  private func clearRecognition() {
    guard captureID != nil else { return }
    captureID = nil
    stopDeadline?.cancel()
    stopDeadline = nil
    stopCapture()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    recognizer = nil
    deactivateAudio()
  }

  private func speak(_ text: String, id: String?, _ reply: FlutterResult) {
    clearRecognition()
    stopSpeaking()
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try session.setActive(true)
    } catch {
      return reply(speechError("暂时无法朗读，请稍后重试。"))
    }
    let next = AVSpeechUtterance(string: text)
    if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
      next.voice = AVSpeechSynthesisVoice(language: language.rawValue)
    }
    utterance = next
    utteranceID = id
    synthesizer.speak(next)
    reply(nil)
  }

  private func stopSpeaking() {
    guard utterance != nil else { return }
    utterance = nil
    utteranceID = nil
    synthesizer.stopSpeaking(at: .immediate)
    deactivateAudio()
  }

  private func deactivateAudio() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish finished: AVSpeechUtterance) {
    completeSpeech(finished)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel cancelled: AVSpeechUtterance) {
    completeSpeech(cancelled)
  }

  private func completeSpeech(_ finished: AVSpeechUtterance) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.utterance === finished else { return }
      let id = self.utteranceID
      self.utterance = nil
      self.utteranceID = nil
      self.deactivateAudio()
      self.emitSpeechDone(id)
    }
  }

  private func emitSpeechDone(_ id: String?) {
    var event = ["type": "speechDone"]
    if let id { event["id"] = id }
    sink?(event)
  }

  private func speechError(_ message: String) -> FlutterError {
    FlutterError(code: "voice", message: message, details: nil)
  }

  private func updateLiveActivity(state: String, title: String?, reply: @escaping FlutterResult) {
    guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
      return reply(nil)
    }
    let label: String
    switch state.uppercased() {
    case "THINKING": label = "AI 正在处理"
    case "QUESTION": label = "AI 等待确认"
    default: return finishLiveActivity(reply)
    }
    let content = ActivityContent(
      state: RobotActivityAttributes.ContentState(
        label: label, title: String((title ?? "Robot Eyes").prefix(64))),
      staleDate: .now.addingTimeInterval(900))
    let previousAction = liveActivityAction
    liveActivityAction = Task { @MainActor in
      await previousAction?.value
      if let activity = Activity<RobotActivityAttributes>.activities.first {
        await activity.update(content)
      } else {
        do {
          _ = try Activity.request(attributes: RobotActivityAttributes(), content: content)
        } catch {
          return reply(FlutterError(code: "live_activity", message: "无法启动实况活动。", details: nil))
        }
      }
      reply(nil)
    }
  }

  private func finishLiveActivity(_ reply: @escaping FlutterResult) {
    guard #available(iOS 16.2, *) else { return reply(nil) }
    let previousAction = liveActivityAction
    liveActivityAction = Task { @MainActor in
      await previousAction?.value
      for activity in Activity<RobotActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      reply(nil)
    }
  }
}

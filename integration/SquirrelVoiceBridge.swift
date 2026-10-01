import AppKit

/// Minimal process bridge between Squirrel and the native R2T2 helper.
/// The helper owns microphone capture and inference. Squirrel only sends
/// START/STOP and receives append-only stable text deltas.
final class SquirrelVoiceBridge {
  private enum State {
    case stopped
    case launching
    case ready
    case starting
    case listening
    case stopping
  }

  private let queue = DispatchQueue(label: "im.rime.squirrel.voice-bridge")
  private let onDelta: (String) -> Void
  private let onPreparing: () -> Void
  private let onStarted: () -> Void
  private let onStopped: () -> Void
  private let onLevel: (Double) -> Void
  private let onError: (String) -> Void

  private var state: State = .stopped
  private var pendingStart = false
  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var outputBuffer = Data()
  private var idleShutdownWorkItem: DispatchWorkItem?

  private var idleUnloadDelay: TimeInterval {
    if let raw = ProcessInfo.processInfo.environment["SQUIRREL_VOICE_IDLE_SECONDS"],
       let value = TimeInterval(raw), value >= 0 {
      return value
    }
    return 300
  }

  init(onDelta: @escaping (String) -> Void,
       onPreparing: @escaping () -> Void = {},
       onStarted: @escaping () -> Void = {},
       onStopped: @escaping () -> Void = {},
       onLevel: @escaping (Double) -> Void = { _ in },
       onError: @escaping (String) -> Void = { message in print("[Squirrel Voice] \(message)") }) {
    self.onDelta = onDelta
    self.onPreparing = onPreparing
    self.onStarted = onStarted
    self.onStopped = onStopped
    self.onLevel = onLevel
    self.onError = onError
  }

  var isActive: Bool {
    queue.sync {
      switch state {
      case .launching, .starting, .listening, .stopping:
        true
      case .stopped, .ready:
        false
      }
    }
  }

  func toggle() {
    queue.async { [weak self] in
      guard let self else { return }
      self.cancelIdleShutdown()
      switch self.state {
      case .stopped:
        self.pendingStart = true
        self.reportPreparing()
        self.launch()
      case .launching:
        self.pendingStart.toggle()
        if !self.pendingStart { self.reportStopped() }
      case .ready:
        self.reportPreparing()
        self.startListening()
      case .starting, .listening:
        self.stopListening()
      case .stopping:
        self.pendingStart = true
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.pendingStart = false
      switch self.state {
      case .starting, .listening:
        self.stopListening()
      case .launching:
        self.reportStopped()
        break
      case .stopped, .ready, .stopping:
        break
      }
    }
  }

  func shutdown() {
    queue.sync {
      cancelIdleShutdown()
      pendingStart = false
      if process?.isRunning == true {
        send("QUIT")
        process?.terminate()
      }
      cleanup()
    }
  }
}

private extension SquirrelVoiceBridge {
  func resolveHelperURL() -> URL? {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["SQUIRREL_VOICE_HELPER"],
       fm.isExecutableFile(atPath: override) {
      return URL(fileURLWithPath: override)
    }

    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true)
      .appendingPathComponent("squirrel-voice", isDirectory: false)
    if fm.isExecutableFile(atPath: bundled.path) {
      return bundled
    }

    let support = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Squirrel Voice", isDirectory: true)
      .appendingPathComponent("squirrel-voice", isDirectory: false)
    if fm.isExecutableFile(atPath: support.path) {
      return support
    }
    return nil
  }

  func launch() {
    guard state == .stopped else { return }
    guard let helperURL = resolveHelperURL() else {
      fail("helper not found; expected Contents/Helpers/squirrel-voice")
      return
    }

    state = .launching
    outputBuffer.removeAll(keepingCapacity: true)

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    let child = Process()
    child.executableURL = helperURL
    child.arguments = ["--stdio"]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = error

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.queue.async { [weak self] in self?.consumeOutput(data) }
    }
    // Drain stderr so the child can never block on a full diagnostic pipe.
    error.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    child.terminationHandler = { [weak self] _ in
      self?.queue.async { [weak self] in
        guard let self else { return }
        let wasExpected = self.state == .stopped
        self.cleanup()
        if !wasExpected {
          self.reportError("voice helper exited")
        }
      }
    }

    do {
      try child.run()
      process = child
      inputPipe = input
      outputPipe = output
      errorPipe = error
    } catch {
      cleanup()
      fail("cannot launch voice helper: \(error.localizedDescription)")
    }
  }

  func consumeOutput(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let lineData = outputBuffer[..<newline]
      outputBuffer.removeSubrange(...newline)
      guard let line = String(data: lineData, encoding: .utf8) else { continue }
      handleLine(line.hasSuffix("\r") ? String(line.dropLast()) : line)
    }
  }

  func handleLine(_ line: String) {
    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    let event = String(parts.first ?? "")
    let value = parts.count > 1 ? unescape(String(parts[1])) : ""

    switch event {
    case "READY":
      state = .ready
      if pendingStart {
        pendingStart = false
        startListening()
      } else {
        scheduleIdleShutdown()
      }
    case "STARTED":
      state = .listening
      reportStarted()
    case "D":
      guard !value.isEmpty else { return }
      DispatchQueue.main.async { [onDelta] in onDelta(value) }
    case "L":
      guard let level = Double(value) else { return }
      reportLevel(level)
    case "STOPPED":
      state = .ready
      reportStopped()
      if pendingStart {
        pendingStart = false
        startListening()
      } else {
        scheduleIdleShutdown()
      }
    case "ERROR":
      state = .ready
      reportStopped()
      reportError(value.isEmpty ? "voice helper error" : value)
    case "PONG":
      break
    default:
      if !line.isEmpty { reportError("unexpected helper event: \(line)") }
    }
  }

  func startListening() {
    guard state == .ready else { return }
    cancelIdleShutdown()
    state = .starting
    send("START")
  }

  func scheduleIdleShutdown() {
    cancelIdleShutdown()
    guard idleUnloadDelay > 0 else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.state == .ready else { return }
      self.pendingStart = false
      self.state = .stopped
      self.send("QUIT")
    }
    idleShutdownWorkItem = work
    queue.asyncAfter(deadline: .now() + idleUnloadDelay, execute: work)
  }

  func cancelIdleShutdown() {
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
  }

  func stopListening() {
    guard state == .starting || state == .listening else { return }
    state = .stopping
    reportStopped()
    send("STOP")
  }

  func send(_ command: String) {
    guard let handle = inputPipe?.fileHandleForWriting else {
      fail("voice helper stdin is unavailable")
      return
    }
    do {
      try handle.write(contentsOf: Data((command + "\n").utf8))
    } catch {
      fail("cannot write to voice helper: \(error.localizedDescription)")
    }
  }

  func unescape(_ value: String) -> String {
    var result = ""
    var escaping = false
    for ch in value {
      if escaping {
        switch ch {
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        case "\\": result.append("\\")
        default:
          result.append("\\")
          result.append(ch)
        }
        escaping = false
      } else if ch == "\\" {
        escaping = true
      } else {
        result.append(ch)
      }
    }
    if escaping { result.append("\\") }
    return result
  }

  func fail(_ message: String) {
    cleanup()
    reportError(message)
  }

  func reportError(_ message: String) {
    DispatchQueue.main.async { [onError] in onError(message) }
  }

  func reportPreparing() {
    DispatchQueue.main.async { [onPreparing] in onPreparing() }
  }

  func reportStarted() {
    DispatchQueue.main.async { [onStarted] in onStarted() }
  }

  func reportStopped() {
    DispatchQueue.main.async { [onStopped] in onStopped() }
  }

  func reportLevel(_ level: Double) {
    DispatchQueue.main.async { [onLevel] in onLevel(level) }
  }

  func cleanup() {
    cancelIdleShutdown()
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    try? inputPipe?.fileHandleForWriting.close()
    try? outputPipe?.fileHandleForReading.close()
    try? errorPipe?.fileHandleForReading.close()
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    outputBuffer.removeAll(keepingCapacity: false)
    state = .stopped
  }
}

final class SquirrelVoiceHUD: NSPanel {
  private final class WaveView: NSView {
    private var band = 0

    func setLevel(_ level: Double) {
      let normalized = max(0, min(1, level))
      let newBand: Int
      switch normalized {
      case ..<0.04: newBand = 0
      case ..<0.12: newBand = 1
      case ..<0.28: newBand = 2
      case ..<0.55: newBand = 3
      default: newBand = 4
      }
      guard newBand != band else { return }
      band = newBand
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      let patterns: [[CGFloat]] = [
        [4, 4, 4, 4, 4],
        [4, 7, 10, 7, 4],
        [5, 10, 14, 10, 5],
        [7, 13, 18, 13, 7],
        [9, 17, 21, 17, 9]
      ]
      let barWidth: CGFloat = 3
      let gap: CGFloat = 3
      let heights = patterns[band]
      let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
      var x = (bounds.width - total) / 2
      NSColor.labelColor.withAlphaComponent(0.9).setFill()
      for height in heights {
        let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        x += barWidth + gap
      }
    }
  }

  var onCancel: (() -> Void)?

  private let root = NSView()
  private let symbol = NSImageView()
  private let wave = WaveView()
  private let label = NSTextField(labelWithString: "")
  private let cancelButton = NSButton()
  private var lastLevelUpdate: TimeInterval = 0

  init() {
    let rect = NSRect(x: 0, y: 0, width: 164, height: 36)
    super.init(contentRect: rect, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .popUpMenu
    ignoresMouseEvents = false
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

    root.frame = NSRect(origin: .zero, size: rect.size)
    root.autoresizingMask = [.width, .height]
    root.wantsLayer = true
    root.layer?.cornerRadius = 18
    root.layer?.borderWidth = 0.5
    root.layer?.masksToBounds = true

    let symbolImage = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Voice input")
      ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice input")
      ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice input")
    symbol.image = symbolImage
    symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    symbol.contentTintColor = .labelColor
    symbol.imageScaling = .scaleProportionallyDown

    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .labelColor
    label.alignment = .left
    label.lineBreakMode = .byTruncatingTail
    label.usesSingleLineMode = true

    cancelButton.isBordered = false
    cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel voice input")
    cancelButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    cancelButton.contentTintColor = .secondaryLabelColor
    cancelButton.target = self
    cancelButton.action = #selector(cancelPressed)
    cancelButton.toolTip = localized(chinese: "取消语音输入", english: "Cancel voice input")

    [symbol, wave, label, cancelButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview($0)
    }

    NSLayoutConstraint.activate([
      symbol.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      symbol.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      symbol.widthAnchor.constraint(equalToConstant: 20),
      symbol.heightAnchor.constraint(equalToConstant: 20),

      wave.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 4),
      wave.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      wave.widthAnchor.constraint(equalToConstant: 29),
      wave.heightAnchor.constraint(equalToConstant: 22),

      label.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: 7),
      label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      label.widthAnchor.constraint(equalToConstant: 62),
      label.heightAnchor.constraint(equalToConstant: 20),

      cancelButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
      cancelButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      cancelButton.widthAnchor.constraint(equalToConstant: 24),
      cancelButton.heightAnchor.constraint(equalToConstant: 24)
    ])
    contentView = root
    updateAppearance()
  }

  func showPreparing(anchor: NSRect) {
    wave.setLevel(0)
    label.stringValue = localized(chinese: "准备中…", english: "Preparing…")
    show(anchor: anchor)
  }

  func showListening(anchor: NSRect) {
    label.stringValue = localized(chinese: "正在听…", english: "Listening…")
    show(anchor: anchor)
  }

  func update(level: Double) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastLevelUpdate >= 0.12 else { return }
    lastLevelUpdate = now
    wave.setLevel(level)
  }

  func hideVoiceHUD() {
    orderOut(nil)
  }

  private func show(anchor: NSRect) {
    updateAppearance()
    let size = frame.size
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var x = anchor.minX
    var y = anchor.minY - size.height - 8
    if y < visible.minY { y = anchor.maxY + 8 }
    x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
    y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
    setFrameOrigin(NSPoint(x: x, y: y))
    orderFrontRegardless()
  }

  @objc private func cancelPressed() {
    onCancel?()
  }

  private func updateAppearance() {
    let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    if match == .darkAqua {
      root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
      root.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor
    } else {
      root.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 0.96).cgColor
      root.layer?.borderColor = NSColor(calibratedWhite: 0.0, alpha: 0.12).cgColor
    }
  }

  private func localized(chinese: String, english: String) -> String {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? chinese : english
  }
}

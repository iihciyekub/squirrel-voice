import AppKit

struct SquirrelVoiceModel: Codable, Equatable {
  enum Source: String, Codable {
    case lmStudio
    case squirrelVoice
    case custom

    var title: String {
      switch self {
      case .lmStudio: "LM Studio"
      case .squirrelVoice: "Squirrel Voice"
      case .custom: "Custom"
      }
    }
  }

  let displayName: String
  let shortName: String
  let variant: String
  let engine: String
  let modelPath: String
  let mmprojPath: String
  let source: Source
  let sizeBytes: Int64

  var id: String { modelPath + "|" + mmprojPath }
}

final class SquirrelVoiceModelStore {
  static let shared = SquirrelVoiceModelStore()

  private let defaults = UserDefaults.standard
  private let selectedKey = "SquirrelVoice.SelectedModel"
  private let customDirectoryKey = "SquirrelVoice.CustomModelDirectory"

  private init() {}

  var customDirectory: URL? {
    get {
      guard let path = defaults.string(forKey: customDirectoryKey), !path.isEmpty else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    set {
      defaults.set(newValue?.path, forKey: customDirectoryKey)
    }
  }

  func selectedModel() -> SquirrelVoiceModel? {
    guard let data = defaults.data(forKey: selectedKey),
          let model = try? JSONDecoder().decode(SquirrelVoiceModel.self, from: data),
          FileManager.default.fileExists(atPath: model.modelPath),
          FileManager.default.fileExists(atPath: model.mmprojPath) else {
      return nil
    }
    return model
  }

  func activeModel() -> SquirrelVoiceModel? {
    if let selected = selectedModel() { return selected }
    return discoverRecommendedDefault()
  }

  func select(_ model: SquirrelVoiceModel) {
    guard let data = try? JSONEncoder().encode(model) else { return }
    defaults.set(data, forKey: selectedKey)
  }

  func scanModels() -> [SquirrelVoiceModel] {
    let fm = FileManager.default
    var roots: [(URL, SquirrelVoiceModel.Source)] = []
    let home = fm.homeDirectoryForCurrentUser

    let lmStudio = home.appendingPathComponent(".lmstudio/models", isDirectory: true)
    if fm.fileExists(atPath: lmStudio.path) { roots.append((lmStudio, .lmStudio)) }

    let squirrelModels = home
      .appendingPathComponent("Library/Application Support/Squirrel Voice/Models", isDirectory: true)
    if fm.fileExists(atPath: squirrelModels.path) { roots.append((squirrelModels, .squirrelVoice)) }

    if let customDirectory, fm.fileExists(atPath: customDirectory.path) {
      roots.append((customDirectory, .custom))
    }

    var result: [SquirrelVoiceModel] = []
    var seen = Set<String>()
    for (root, source) in roots {
      for model in scan(root: root, source: source) where seen.insert(model.id).inserted {
        result.append(model)
      }
    }

    return result.sorted { lhs, rhs in
      if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
      return variantRank(lhs.variant) < variantRank(rhs.variant)
    }
  }

  func lmStudioRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".lmstudio/models", isDirectory: true)
  }

  private func discoverRecommendedDefault() -> SquirrelVoiceModel? {
    let root = lmStudioRoot()
      .appendingPathComponent("netease-youdao/Confucius4-R2T2-GGUF", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    return scanDirectory(root, source: .lmStudio).sorted {
      variantRank($0.variant) < variantRank($1.variant)
    }.first
  }

  private func scan(root: URL, source: SquirrelVoiceModel.Source) -> [SquirrelVoiceModel] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }

    var directories = Set<URL>()
    for case let url as URL in enumerator {
      guard url.pathExtension.lowercased() == "gguf" else { continue }
      directories.insert(url.deletingLastPathComponent())
    }

    return directories.flatMap { scanDirectory($0, source: source) }
  }

  private func scanDirectory(_ directory: URL, source: SquirrelVoiceModel.Source) -> [SquirrelVoiceModel] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
    let projectors = ggufs.filter { $0.lastPathComponent.lowercased().hasPrefix("mmproj-") }
    guard !projectors.isEmpty else { return [] }

    // Automatic compatibility is intentionally conservative for v0.1. We
    // only enable the R2T2 family that this runtime has actually been tested
    // against. The model record already carries an engine field so future
    // speech engines can be added without changing the settings UI.
    let candidates = ggufs.filter {
      !$0.lastPathComponent.lowercased().hasPrefix("mmproj-") &&
      ($0.lastPathComponent.lowercased().contains("r2t2") ||
       directory.lastPathComponent.lowercased().contains("r2t2"))
    }

    return candidates.compactMap { modelURL in
      guard let projector = preferredProjector(from: projectors, for: modelURL) else { return nil }
      let variant = variantName(modelURL.lastPathComponent)
      let size = fileSize(modelURL) + fileSize(projector)
      return SquirrelVoiceModel(
        displayName: familyName(modelURL.lastPathComponent),
        shortName: modelURL.lastPathComponent.lowercased().contains("r2t2") ? "R2T2" : "ASR",
        variant: variant,
        engine: "r2t2-llama",
        modelPath: modelURL.path,
        mmprojPath: projector.path,
        source: source,
        sizeBytes: size
      )
    }
  }

  private func preferredProjector(from projectors: [URL], for model: URL) -> URL? {
    let lower = model.lastPathComponent.lowercased()
    if lower.contains("f16"),
       let f16 = projectors.first(where: { $0.lastPathComponent.lowercased().contains("f16") }) {
      return f16
    }
    if let q8 = projectors.first(where: { $0.lastPathComponent.lowercased().contains("q8") }) {
      return q8
    }
    return projectors.first
  }

  private func familyName(_ filename: String) -> String {
    if filename.lowercased().contains("confucius4-r2t2") { return "Confucius4-R2T2" }
    var name = (filename as NSString).deletingPathExtension
    for suffix in ["-Q4_K_M", "-Q8_0", "-f16", "-F16"] where name.hasSuffix(suffix) {
      name.removeLast(suffix.count)
      break
    }
    return name
  }

  private func variantName(_ filename: String) -> String {
    let lower = filename.lowercased()
    if lower.contains("q4_k_m") { return "Q4_K_M" }
    if lower.contains("q8_0") { return "Q8_0" }
    if lower.contains("f16") { return "F16" }
    return "GGUF"
  }

  private func variantRank(_ variant: String) -> Int {
    switch variant {
    case "Q4_K_M": 0
    case "Q8_0": 1
    case "F16": 2
    default: 3
    }
  }

  private func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? 0)
  }
}

final class SquirrelVoiceSettingsController: NSObject, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource {
  var onModelChanged: (() -> Void)?

  private let store = SquirrelVoiceModelStore.shared
  private var models: [SquirrelVoiceModel] = []
  private var window: NSWindow?
  private let currentTitle = NSTextField(labelWithString: "")
  private let currentDetail = NSTextField(labelWithString: "")
  private let customPath = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private let useButton = NSButton(title: "", target: nil, action: nil)
  private let revealButton = NSButton(title: "", target: nil, action: nil)

  func show() {
    if window == nil { buildWindow() }
    updateCurrentCard()
    updateSourcePath()
    rescan()
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func buildWindow() {
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    w.title = localized("语音输入", "Voice Input")
    w.isReleasedWhenClosed = false
    w.delegate = self

    let root = NSView()
    w.contentView = root

    let title = NSTextField(labelWithString: localized("语音输入", "Voice Input"))
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    let subtitle = NSTextField(labelWithString: localized(
      "选择本地语音模型。LM Studio 只作为模型目录，不需要运行。",
      "Choose a local speech model. LM Studio is only used as a model folder."
    ))
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor

    let currentBox = NSBox()
    currentBox.boxType = .custom
    currentBox.cornerRadius = 12
    currentBox.borderColor = .separatorColor
    currentBox.fillColor = .controlBackgroundColor
    let currentIcon = NSImageView(image: NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Voice model") ?? NSImage())
    currentIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
    currentIcon.contentTintColor = .labelColor
    currentTitle.font = .systemFont(ofSize: 14, weight: .semibold)
    currentDetail.font = .systemFont(ofSize: 11)
    currentDetail.textColor = .secondaryLabelColor
    currentDetail.lineBreakMode = .byTruncatingMiddle
    [currentIcon, currentTitle, currentDetail].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      currentBox.addSubview($0)
    }

    let sourcesLabel = NSTextField(labelWithString: localized("模型来源", "Model Sources"))
    sourcesLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    let lmPath = NSTextField(labelWithString: store.lmStudioRoot().path)
    lmPath.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    lmPath.textColor = .secondaryLabelColor
    lmPath.lineBreakMode = .byTruncatingMiddle
    let scanButton = NSButton(title: localized("扫描 LM Studio", "Scan LM Studio"), target: self, action: #selector(scanPressed))
    let chooseButton = NSButton(title: localized("选择其它目录…", "Choose Folder…"), target: self, action: #selector(chooseFolder))
    let clearButton = NSButton(title: localized("清除", "Clear"), target: self, action: #selector(clearCustomFolder))
    customPath.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    customPath.textColor = .secondaryLabelColor
    customPath.lineBreakMode = .byTruncatingMiddle

    [scanButton, chooseButton, clearButton].forEach {
      $0.setContentHuggingPriority(.required, for: .horizontal)
      $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    lmPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    customPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let lmRow = NSStackView(views: [lmPath, scanButton])
    lmRow.orientation = .horizontal
    lmRow.alignment = .centerY
    lmRow.spacing = 8
    lmRow.distribution = .fill

    let customRow = NSStackView(views: [customPath, chooseButton, clearButton])
    customRow.orientation = .horizontal
    customRow.alignment = .centerY
    customRow.spacing = 8
    customRow.distribution = .fill

    let availableLabel = NSTextField(labelWithString: localized("可用模型", "Available Models"))
    availableLabel.font = .systemFont(ofSize: 13, weight: .semibold)

    tableView.headerView = NSTableHeaderView()
    tableView.rowSizeStyle = .medium
    tableView.allowsMultipleSelection = false
    tableView.delegate = self
    tableView.dataSource = self
    let columns: [(String, String, CGFloat)] = [
      ("active", "", 30),
      ("model", localized("模型", "Model"), 178),
      ("variant", localized("版本", "Variant"), 80),
      ("source", localized("来源", "Source"), 94),
      ("size", localized("大小", "Size"), 76)
    ]
    for (id, titleText, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = titleText
      column.width = width
      if id == "active" {
        column.minWidth = width
        column.maxWidth = width
        column.resizingMask = []
      }
      tableView.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder

    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 2

    let recommended = NSTextField(labelWithString: localized(
      "默认推荐：NetEase Youdao · Confucius4-R2T2-GGUF",
      "Recommended: NetEase Youdao · Confucius4-R2T2-GGUF"
    ))
    recommended.font = .systemFont(ofSize: 11)
    recommended.textColor = .secondaryLabelColor
    let viewModelButton = NSButton(title: localized("查看模型页", "Model Page"), target: self, action: #selector(openRecommendedModel))
    revealButton.title = localized("在 Finder 中显示", "Reveal in Finder")
    revealButton.target = self
    revealButton.action = #selector(revealSelected)
    useButton.title = localized("使用所选模型", "Use Selected Model")
    useButton.target = self
    useButton.action = #selector(useSelected)
    useButton.keyEquivalent = "\r"

    let views: [NSView] = [
      title, subtitle, currentBox, sourcesLabel, lmRow, customRow,
      availableLabel, scroll, statusLabel, recommended,
      viewModelButton, revealButton, useButton
    ]
    views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }

    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
      subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

      currentBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      currentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      currentBox.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
      currentBox.heightAnchor.constraint(equalToConstant: 68),
      currentIcon.leadingAnchor.constraint(equalTo: currentBox.leadingAnchor, constant: 14),
      currentIcon.centerYAnchor.constraint(equalTo: currentBox.centerYAnchor),
      currentIcon.widthAnchor.constraint(equalToConstant: 28),
      currentIcon.heightAnchor.constraint(equalToConstant: 28),
      currentTitle.leadingAnchor.constraint(equalTo: currentIcon.trailingAnchor, constant: 12),
      currentTitle.topAnchor.constraint(equalTo: currentBox.topAnchor, constant: 14),
      currentTitle.trailingAnchor.constraint(equalTo: currentBox.trailingAnchor, constant: -14),
      currentDetail.leadingAnchor.constraint(equalTo: currentTitle.leadingAnchor),
      currentDetail.topAnchor.constraint(equalTo: currentTitle.bottomAnchor, constant: 3),
      currentDetail.trailingAnchor.constraint(equalTo: currentBox.trailingAnchor, constant: -14),

      sourcesLabel.leadingAnchor.constraint(equalTo: currentBox.leadingAnchor),
      sourcesLabel.topAnchor.constraint(equalTo: currentBox.bottomAnchor, constant: 13),
      lmRow.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
      lmRow.trailingAnchor.constraint(equalTo: currentBox.trailingAnchor),
      lmRow.topAnchor.constraint(equalTo: sourcesLabel.bottomAnchor, constant: 6),
      lmRow.heightAnchor.constraint(equalToConstant: 28),

      customRow.leadingAnchor.constraint(equalTo: sourcesLabel.leadingAnchor),
      customRow.trailingAnchor.constraint(equalTo: currentBox.trailingAnchor),
      customRow.topAnchor.constraint(equalTo: lmRow.bottomAnchor, constant: 5),
      customRow.heightAnchor.constraint(equalToConstant: 28),

      availableLabel.leadingAnchor.constraint(equalTo: currentBox.leadingAnchor),
      availableLabel.topAnchor.constraint(equalTo: customRow.bottomAnchor, constant: 13),
      scroll.leadingAnchor.constraint(equalTo: currentBox.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: currentBox.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: availableLabel.bottomAnchor, constant: 6),
      scroll.heightAnchor.constraint(equalToConstant: 150),
      statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
      statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 5),
      statusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
      statusLabel.heightAnchor.constraint(equalToConstant: 30),

      recommended.leadingAnchor.constraint(equalTo: currentBox.leadingAnchor),
      recommended.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 7),
      viewModelButton.leadingAnchor.constraint(equalTo: recommended.trailingAnchor, constant: 8),
      viewModelButton.centerYAnchor.constraint(equalTo: recommended.centerYAnchor),

      useButton.trailingAnchor.constraint(equalTo: currentBox.trailingAnchor),
      useButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      revealButton.trailingAnchor.constraint(equalTo: useButton.leadingAnchor, constant: -8),
      revealButton.centerYAnchor.constraint(equalTo: useButton.centerYAnchor)
    ])

    window = w
  }

  private func rescan() {
    statusLabel.stringValue = localized("正在扫描模型…", "Scanning models…")
    useButton.isEnabled = false
    revealButton.isEnabled = false
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let found = self.store.scanModels()
      DispatchQueue.main.async {
        self.models = found
        self.tableView.reloadData()
        self.statusLabel.stringValue = found.isEmpty
          ? self.localized(
              "未找到语音模型。请先用 LM Studio 下载 Confucius4-R2T2 Q4_K_M + mmproj，下载完成后点「扫描 LM Studio」；也可以选择其它目录。",
              "No voice model found. Download Confucius4-R2T2 Q4_K_M + mmproj in LM Studio, then click Scan LM Studio, or choose another folder."
            )
          : self.localized("找到 \(found.count) 个可用模型。", "Found \(found.count) usable models.")
        if let active = self.store.activeModel(),
           let row = found.firstIndex(where: { $0.id == active.id }) {
          self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          self.tableView.scrollRowToVisible(row)
        }
        self.updateButtons()
        self.updateCurrentCard()
      }
    }
  }

  private func updateCurrentCard() {
    guard let model = store.activeModel() else {
      currentTitle.stringValue = localized("未选择语音模型", "No Voice Model Selected")
      currentDetail.stringValue = localized("扫描 LM Studio 或选择其它模型目录", "Scan LM Studio or choose another model folder")
      return
    }
    currentTitle.stringValue = "\(model.displayName) · \(model.variant)"
    currentDetail.stringValue = "\(model.source.title) · \(model.engine) · \(model.modelPath)"
  }

  private func updateSourcePath() {
    customPath.stringValue = store.customDirectory?.path ?? localized("未指定其它目录", "No custom folder selected")
  }

  private func updateButtons() {
    let valid = tableView.selectedRow >= 0 && tableView.selectedRow < models.count
    useButton.isEnabled = valid
    revealButton.isEnabled = valid
  }

  func numberOfRows(in tableView: NSTableView) -> Int { models.count }

  func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard row < models.count, let column = tableColumn else { return nil }
    let model = models[row]
    if column.identifier.rawValue == "active" {
      let imageView = NSImageView()
      imageView.imageScaling = .scaleProportionallyDown
      imageView.contentTintColor = .systemGreen
      imageView.image = model.id == store.activeModel()?.id
        ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: localized("当前模型", "Current model"))
        : nil
      imageView.toolTip = model.id == store.activeModel()?.id
        ? localized("当前正在使用", "Currently in use")
        : nil
      return imageView
    }
    let value: String
    switch column.identifier.rawValue {
    case "model": value = model.displayName
    case "variant": value = model.variant
    case "source": value = model.source.title
    case "size": value = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
    default: value = ""
    }
    let field = NSTextField(labelWithString: value)
    field.lineBreakMode = .byTruncatingTail
    field.toolTip = column.identifier.rawValue == "model" ? model.modelPath : nil
    return field
  }

  @objc private func scanPressed() { rescan() }

  @objc private func chooseFolder() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = localized("选择", "Choose")
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.store.customDirectory = url
      self.updateSourcePath()
      self.rescan()
    }
  }

  @objc private func clearCustomFolder() {
    store.customDirectory = nil
    updateSourcePath()
    rescan()
  }

  @objc private func useSelected() {
    let row = tableView.selectedRow
    guard row >= 0, row < models.count else { return }
    store.select(models[row])
    updateCurrentCard()
    tableView.reloadData()
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    onModelChanged?()
  }

  @objc private func revealSelected() {
    let row = tableView.selectedRow
    guard row >= 0, row < models.count else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: models[row].modelPath)])
  }

  @objc private func openRecommendedModel() {
    if let url = URL(string: "https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF") {
      NSWorkspace.shared.open(url)
    }
  }

  private func localized(_ chinese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? chinese : english
  }
}

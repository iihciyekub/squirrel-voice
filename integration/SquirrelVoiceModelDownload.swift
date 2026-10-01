import Foundation

final class SquirrelVoiceModelDownloadManager: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
  enum Phase: Equatable {
    case idle
    case downloading
    case paused
    case failed
    case completed
  }

  struct Snapshot {
    let phase: Phase
    let progress: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let currentFile: String?
    let errorMessage: String?
  }

  private struct FileSpec {
    let name: String
    let url: URL
    let expectedBytes: Int64
  }

  static let shared = SquirrelVoiceModelDownloadManager()

  var onUpdate: ((Snapshot) -> Void)? {
    didSet { publish() }
  }

  private let files: [FileSpec] = [
    FileSpec(
      name: "Confucius4-R2T2-Q4_K_M.gguf",
      url: URL(string: "https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF/resolve/main/Confucius4-R2T2-Q4_K_M.gguf?download=true")!,
      expectedBytes: 1_107_404_736
    ),
    FileSpec(
      name: "mmproj-Confucius4-R2T2-f16.gguf",
      url: URL(string: "https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF/resolve/main/mmproj-Confucius4-R2T2-f16.gguf?download=true")!,
      expectedBytes: 641_773_984
    )
  ]

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 60 * 60 * 12
    configuration.waitsForConnectivity = true
    let queue = OperationQueue()
    queue.name = "SquirrelVoice.ModelDownload"
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }()

  private var task: URLSessionDownloadTask?
  private var currentIndex = 0
  private var finishedBytes: Int64 = 0
  private var currentBytes: Int64 = 0
  private var phase: Phase = .idle
  private var errorMessage: String?
  private var speedBytesPerSecond: Double = 0
  private var speedSampleBytes: Int64 = 0
  private var speedSampleDate = Date()
  private var userPaused = false

  private override init() {
    super.init()
    if installedFilesAreValid() { phase = .completed }
  }

  var totalBytes: Int64 { files.reduce(0) { $0 + $1.expectedBytes } }

  func targetDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Squirrel Voice/Models/netease-youdao/Confucius4-R2T2-GGUF", isDirectory: true)
  }

  func isInstalled() -> Bool { installedFilesAreValid() }

  func startOrResume() {
    DispatchQueue.main.async { [weak self] in self?.startOrResumeOnMain() }
  }

  func pause() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.phase == .downloading, let task = self.task else { return }
      self.userPaused = true
      task.cancel(byProducingResumeData: { [weak self] resumeData in
        guard let self else { return }
        if let resumeData { try? resumeData.write(to: self.resumeURL(for: self.currentIndex), options: .atomic) }
        DispatchQueue.main.async {
          self.task = nil
          self.phase = .paused
          self.speedBytesPerSecond = 0
          self.publish()
        }
      })
    }
  }

  func removeDownloadedModel() throws {
    guard phase != .downloading else { return }
    let fm = FileManager.default
    let target = targetDirectory()
    for spec in files {
      try? fm.removeItem(at: target.appendingPathComponent(spec.name))
    }
    for index in files.indices { try? fm.removeItem(at: resumeURL(for: index)) }
    phase = .idle
    currentIndex = 0
    finishedBytes = 0
    currentBytes = 0
    errorMessage = nil
    publish()
  }

  private func startOrResumeOnMain() {
    if installedFilesAreValid() {
      phase = .completed
      publish()
      return
    }
    guard phase != .downloading else { return }
    do {
      try FileManager.default.createDirectory(at: targetDirectory(), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: resumeDirectory(), withIntermediateDirectories: true)
    } catch {
      fail(error.localizedDescription)
      return
    }

    currentIndex = firstMissingFileIndex() ?? 0
    finishedBytes = installedBytes(before: currentIndex)
    currentBytes = 0
    errorMessage = nil
    speedBytesPerSecond = 0
    speedSampleBytes = 0
    speedSampleDate = Date()
    userPaused = false
    phase = .downloading

    let resumeURL = resumeURL(for: currentIndex)
    if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
      task = session.downloadTask(withResumeData: resumeData)
    } else {
      task = session.downloadTask(with: files[currentIndex].url)
    }
    publish()
    task?.resume()
  }

  private func startNextFile() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let next = self.firstMissingFileIndex() {
        self.currentIndex = next
        self.finishedBytes = self.installedBytes(before: next)
        self.currentBytes = 0
        self.speedSampleBytes = 0
        self.speedSampleDate = Date()
        self.userPaused = false
        self.phase = .downloading
        self.task = self.session.downloadTask(with: self.files[next].url)
        self.publish()
        self.task?.resume()
      } else {
        self.task = nil
        self.finishedBytes = self.totalBytes
        self.currentBytes = 0
        self.speedBytesPerSecond = 0
        self.phase = .completed
        self.errorMessage = nil
        self.publish()
      }
    }
  }

  private func fail(_ message: String) {
    phase = .failed
    errorMessage = message
    speedBytesPerSecond = 0
    publish()
  }

  private func publish() {
    let downloaded = min(totalBytes, finishedBytes + currentBytes)
    let snapshot = Snapshot(
      phase: phase,
      progress: totalBytes > 0 ? Double(downloaded) / Double(totalBytes) : 0,
      bytesDownloaded: downloaded,
      totalBytes: totalBytes,
      bytesPerSecond: speedBytesPerSecond,
      currentFile: phase == .downloading && currentIndex < files.count ? files[currentIndex].name : nil,
      errorMessage: errorMessage
    )
    DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
  }

  private func resumeDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Squirrel Voice/Downloads", isDirectory: true)
  }

  private func resumeURL(for index: Int) -> URL {
    resumeDirectory().appendingPathComponent("recommended-\(index).resume")
  }

  private func firstMissingFileIndex() -> Int? {
    files.indices.first { !validGGUF(at: targetDirectory().appendingPathComponent(files[$0].name)) }
  }

  private func installedBytes(before index: Int) -> Int64 {
    guard index > 0 else { return 0 }
    return files[..<index].reduce(0) { partial, spec in
      validGGUF(at: targetDirectory().appendingPathComponent(spec.name)) ? partial + spec.expectedBytes : partial
    }
  }

  private func installedFilesAreValid() -> Bool {
    files.allSatisfy { validGGUF(at: targetDirectory().appendingPathComponent($0.name)) }
  }

  private func validGGUF(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4), data == Data([0x47, 0x47, 0x55, 0x46]) else { return false }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return size > 100_000_000
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let now = Date()
    let elapsed = now.timeIntervalSince(speedSampleDate)
    if elapsed >= 0.35 {
      let delta = max(0, totalBytesWritten - speedSampleBytes)
      speedBytesPerSecond = Double(delta) / elapsed
      speedSampleBytes = totalBytesWritten
      speedSampleDate = now
    }
    currentBytes = min(files[currentIndex].expectedBytes, totalBytesWritten)
    publish()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let index = currentIndex
    guard index < files.count else { return }
    let destination = targetDirectory().appendingPathComponent(files[index].name)
    do {
      guard validGGUF(at: location) else { throw NSError(domain: "SquirrelVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloaded file is not a valid GGUF model."]) }
      try FileManager.default.createDirectory(at: targetDirectory(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
      try? FileManager.default.removeItem(at: resumeURL(for: index))
      startNextFile()
    } catch {
      DispatchQueue.main.async { [weak self] in self?.fail(error.localizedDescription) }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    if userPaused && (error as NSError).code == NSURLErrorCancelled { return }
    let nsError = error as NSError
    if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
      try? resumeData.write(to: resumeURL(for: currentIndex), options: .atomic)
    }
    DispatchQueue.main.async { [weak self] in
      self?.task = nil
      self?.fail(error.localizedDescription)
    }
  }
}

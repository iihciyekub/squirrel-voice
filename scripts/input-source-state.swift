import Foundation
import Carbon

let bundleID = "im.rime.inputmethod.SquirrelVoice"
let sourceIDs = [bundleID, bundleID + ".Hans", bundleID + ".Hant"]

struct SourceState: Codable {
  let enabled: [String: Bool]
  let selected: String?
}

func property(_ source: TISInputSource, _ key: CFString) -> Any? {
  guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
  return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}

func sources() -> [String: TISInputSource] {
  let list = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
  var result: [String: TISInputSource] = [:]
  for source in list {
    if let id = property(source, kTISPropertyInputSourceID) as? String,
       sourceIDs.contains(id) { result[id] = source }
  }
  return result
}

func state() -> SourceState {
  var enabled: [String: Bool] = [:]
  var selected: String?
  for (id, source) in sources() {
    enabled[id] = property(source, kTISPropertyInputSourceIsEnabled) as? Bool ?? false
    if property(source, kTISPropertyInputSourceIsSelected) as? Bool == true {
      selected = id
    }
  }
  return SourceState(enabled: enabled, selected: selected)
}

func check(_ result: OSStatus, _ action: String) throws {
  guard result == noErr else {
    throw NSError(domain: action, code: Int(result))
  }
}

do {
  let args = CommandLine.arguments
  switch args.dropFirst().first {
  case "snapshot" where args.count == 3:
    try JSONEncoder().encode(state()).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
  case "restore" where args.count == 4:
    let saved = try JSONDecoder().decode(SourceState.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    // A fresh or deliberately disabled install must remain disabled.
    if saved.enabled[bundleID] == true {
      if sources()[bundleID] == nil {
        try check(TISRegisterInputSource(URL(fileURLWithPath: args[3]) as CFURL), "Register input method")
      }
      for id in sourceIDs {
        guard let expected = saved.enabled[id] else { continue }
        guard let source = sources()[id] else { throw NSError(domain: "Missing input source: \(id)", code: 1) }
        let actual = property(source, kTISPropertyInputSourceIsEnabled) as? Bool ?? false
        if actual != expected {
          try check(expected ? TISEnableInputSource(source) : TISDisableInputSource(source), "Restore \(id)")
        }
      }
      if let selected = saved.selected, let source = sources()[selected] {
        try check(TISSelectInputSource(source), "Restore selected input source")
      }
      let actual = state()
      guard actual.enabled == saved.enabled, saved.selected == nil || actual.selected == saved.selected else {
        throw NSError(domain: "Input source state did not survive installation", code: 1)
      }
    }
  case "status":
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(state()), as: UTF8.self))
  default:
    fputs("Usage: input-source-state snapshot FILE | restore FILE APP | status\n", stderr)
    exit(2)
  }
} catch {
  fputs("Input source state error: \(error)\n", stderr)
  exit(1)
}

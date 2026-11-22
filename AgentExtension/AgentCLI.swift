import Foundation
import TunaKit

/// How a run ended, as the agent reported it.
enum AgentOutcome: Equatable {
  /// The task was done completely and there is nothing to read.
  case done
  /// Something to read: an answer, a result, or a partial outcome.
  case answer(String)
  /// The run didn't do what was asked. The reason is shown on the Shelf.
  case failed(String)
}

/// The agent command-line tools Ask Agent can hand a request to.
enum AgentCLI: String, CaseIterable, Sendable {
  case claude
  case codex
  case antigravity

  var displayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    case .antigravity: return "Antigravity"
    }
  }

  var executableName: String {
    switch self {
    case .claude: return "claude"
    case .codex: return "codex"
    case .antigravity: return "agy"
    }
  }

  static let timeout: TimeInterval = 600

  /// The structured reply every CLI is asked for.
  static let outcomeSchema = """
    {"type":"object","properties":{"outcome":{"type":"string","enum":["done","answer","failed"]},\
    "message":{"type":"string"}},"required":["outcome","message"],"additionalProperties":false}
    """

  /// Tells the agent it runs once, unattended, and how to report the result. It leads the prompt,
  /// so the prompt never starts with text a CLI could read as an option.
  static let contract = """
    You were started from a launcher for one request, and nobody can answer follow-up questions. \
    Don't ask for confirmation; if the request is unclear or too risky to do unattended, don't do it \
    and report failed. Report how it ended in the structured outcome:
    - "answer" when the user wants to know something: a question, a lookup, a summary, or the \
    output of a command. Use it even if you ran tools to find it. Put the answer in message.
    - "done" only when the user asked you to change something, you changed it completely, and \
    there is nothing they need to read. message is then one short line.
    - "failed" when you could not do it, or did only part. Explain why in message.
    """

  /// The full prompt: the contract, the request, and any selected files or folders.
  static func prompt(_ request: String, paths: [String]) -> String {
    var prompt = contract + "\n\nRequest:\n" + request
    if !paths.isEmpty {
      prompt += "\n\nSelected files and folders:\n" + paths.map { "- " + $0 }.joined(separator: "\n")
    }
    return prompt
  }

  /// Folders outside the home folder the agent needs access to for the selected paths.
  static func extraDirectories(for paths: [String], home: String) -> [String] {
    var directories: [String] = []
    for path in paths {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      let directory = exists && isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
      let inHome = directory == home || directory.hasPrefix(home.hasSuffix("/") ? home : home + "/")
      if !inHome, !directories.contains(directory) { directories.append(directory) }
    }
    return directories
  }

  /// The arguments for one run. Codex writes its reply to `outputFile` and reads its schema from
  /// `schemaFile`; the others print JSON.
  func arguments(prompt: String, extraDirectories: [String], schemaFile: String, outputFile: String)
    -> [String]
  {
    let directories = extraDirectories.flatMap { ["--add-dir", $0] }
    switch self {
    case .claude:
      return ["-p", prompt] + directories + [
        "--output-format", "json", "--json-schema", Self.outcomeSchema,
        "--permission-mode", "auto", "--no-session-persistence",
      ]
    case .codex:
      return ["exec", "--skip-git-repo-check", "--ephemeral", "--approve-for-me"] + directories + [
        "--output-schema", schemaFile, "--output-last-message", outputFile, "--color", "never",
        prompt,
      ]
    case .antigravity:
      return ["-p", prompt, "--output-format", "json", "--json-schema", Self.outcomeSchema,
        "--sandbox", "--print-timeout", "\(Int(Self.timeout))s"] + directories
    }
  }

  /// Reads a finished run. Anything unexpected is a failure, never a silent "done".
  func outcome(of result: CLIProcessResult, lastMessage: String?) -> AgentOutcome {
    guard result.exitCode == 0 else {
      return .failed("\(displayName) exited with code \(result.exitCode). \(Self.tail(result.standardError))")
    }
    switch self {
    case .claude:
      guard let json = Self.object(result.standardOutput) else { return unreadable }
      if json["is_error"] as? Bool == true {
        return .failed((json["result"] as? String).map(Self.tail) ?? "\(displayName) reported an error.")
      }
      return Self.reported(json["structured_output"]) ?? unreadable
    case .codex:
      return Self.reported(lastMessage.flatMap(Self.object)) ?? unreadable
    case .antigravity:
      guard let json = Self.object(result.standardOutput) else { return unreadable }
      guard json["status"] as? String == "SUCCESS" else {
        return .failed("\(displayName) stopped with status \(json["status"] as? String ?? "unknown").")
      }
      return Self.reported(json["structured_output"]) ?? unreadable
    }
  }

  private var unreadable: AgentOutcome {
    .failed("\(displayName) finished, but its reply couldn't be read.")
  }

  private static func reported(_ value: Any?) -> AgentOutcome? {
    guard let reply = value as? [String: Any], let outcome = reply["outcome"] as? String,
      let message = reply["message"] as? String
    else { return nil }
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    switch outcome {
    case "done": return .done
    case "answer": return text.isEmpty ? .failed("The agent returned an empty answer.") : .answer(text)
    case "failed": return .failed(text.isEmpty ? "The agent couldn't do it and gave no reason." : text)
    default: return nil
    }
  }

  private static func object(_ text: String) -> [String: Any]? {
    guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
      return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// The end of an error stream, where CLIs put the reason.
  private static func tail(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 600 ? "…" + trimmed.suffix(600) : trimmed
  }

  /// Tuna's own PATH first, then the usual install folders, since Tuna may start without a shell.
  func locate(
    path: String? = ProcessInfo.processInfo.environment["PATH"],
    home: String = NSHomeDirectory(),
    isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
  ) -> String? {
    searchFolders(path: path, home: home).map { $0 + "/" + executableName }.first(where: isExecutable)
  }

  func searchFolders(path: String?, home: String) -> [String] {
    var folders = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    for folder in ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
    where !folders.contains(folder) {
      folders.append(folder)
    }
    return folders
  }
}

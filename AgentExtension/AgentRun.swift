import AppKit
import Foundation
import TunaKit

/// Runs a process. Tests stand in for the real CLIs here.
protocol AgentProcessRunning: Sendable {
  func run(_ request: CLIProcessRequest) async throws -> CLIProcessResult
}

struct TunaProcessRunner: AgentProcessRunning {
  func run(_ request: CLIProcessRequest) async throws -> CLIProcessResult {
    try await CLIProcessRunner.run(request)
  }
}

/// One request handed to an agent CLI. It runs as a Shelf task while the agent works. "Done" shows
/// a short banner; an answer or a failure comes back into Tuna as text, ready for any text action
/// (including Add to Shelf).
struct AgentRun: Sendable {
  let request: String
  let paths: [String]
  let cli: AgentCLI
  var runner: any AgentProcessRunning = TunaProcessRunner()
  var executable: @Sendable (AgentCLI) -> String? = { $0.locate() }
  var home: String = NSHomeDirectory()
  var announceDone: @MainActor @Sendable () -> Void = { AgentNotice.show("Agent: Done!") }
  var stageText: @MainActor @Sendable (String) -> Void = { AgentStage.text($0) }

  /// A Shelf title: the start of the request on one line.
  var title: String {
    let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? request
    return "Agent: " + (line.count > 60 ? line.prefix(60) + "…" : line)
  }

  var task: CommandBackgroundTask {
    CommandBackgroundTask(title: title, routing: .shelf) { await self.complete() }
  }

  func complete() async -> CommandTaskCompletion {
    let started = Date()
    let outcome = await perform()
    // Only the outcome kind and duration are logged, never the request or the reply.
    let kind: String
    switch outcome {
    case .done: kind = "done"
    case .answer: kind = "answer"
    case .failed: kind = "failed"
    }
    AppLog.info(
      .plugins,
      "[Agent] \(cli.rawValue) finished outcome=\(kind) seconds=\(Int(Date().timeIntervalSince(started)))")

    // The task row only tracks the run; nothing is left on the Shelf.
    switch outcome {
    case .done:
      await announceDone()
    case .answer(let text):
      await stageText(text)
    case .failed(let reason):
      await stageText("Agent couldn't do it: " + reason)
    }
    return .successWithoutResult()
  }

  func perform() async -> AgentOutcome {
    guard let executable = executable(cli) else {
      let folders = cli.searchFolders(path: ProcessInfo.processInfo.environment["PATH"], home: home)
      return .failed(
        "\(cli.displayName) (\(cli.executableName)) isn't installed. Looked in \(folders.joined(separator: ", ")). Pick another agent in the extension's settings, or install it.")
    }

    // Codex reads its schema from a file and writes its reply to one; both are private to this run.
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("tuna-agent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let schemaFile = scratch.appendingPathComponent("schema.json")
    let outputFile = scratch.appendingPathComponent("reply.json")
    do {
      try FileManager.default.createDirectory(
        at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try Data(AgentCLI.outcomeSchema.utf8).write(to: schemaFile)
    } catch {
      return .failed("Couldn't prepare the run: \(error.localizedDescription)")
    }

    let arguments = cli.arguments(
      prompt: AgentCLI.prompt(request, paths: paths),
      extraDirectories: AgentCLI.extraDirectories(for: paths, home: home),
      schemaFile: schemaFile.path, outputFile: outputFile.path)
    // Empty stdin, so a CLI that waits for input ends instead of hanging until the timeout.
    let processRequest = CLIProcessRequest(
      executablePath: executable, arguments: arguments, currentDirectoryPath: home,
      standardInput: Data(), timeout: AgentCLI.timeout)

    do {
      let result = try await runner.run(processRequest)
      let lastMessage = try? String(contentsOf: outputFile, encoding: .utf8)
      return cli.outcome(of: result, lastMessage: lastMessage)
    } catch CLIProcessError.timedOut {
      return .failed(
        "\(cli.displayName) didn't finish within \(Int(AgentCLI.timeout / 60)) minutes and was stopped. Some of the work may already be done.")
    } catch CLIProcessError.cancelled {
      return .failed("Cancelled. Some of the work may already be done.")
    } catch {
      return .failed("Couldn't run \(cli.displayName): \(error.localizedDescription)")
    }
  }
}

/// Puts text into Tuna's subject pane through the documented `tuna://stage` link, without running
/// anything, so the reply can be copied, pasted, shown in Large Type, or added to the Shelf.
@MainActor
enum AgentStage {
  static func url(for text: String) -> URL? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let reference = ("text:" + text).addingPercentEncoding(withAllowedCharacters: allowed)
    else { return nil }
    return URL(string: "tuna://stage?subject=" + reference)
  }

  static func text(_ text: String) {
    guard let url = url(for: text), NSWorkspace.shared.open(url) else {
      AgentNotice.show("Agent: the reply couldn't be shown in Tuna", for: .seconds(4))
      return
    }
  }
}

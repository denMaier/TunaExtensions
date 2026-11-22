import Foundation
import TunaKit
import XCTest

@testable import AgentExtension

/// Stands in for a CLI: records the request and answers with a canned result, or throws.
private final class StubRunner: AgentProcessRunning, @unchecked Sendable {
  var result = CLIProcessResult(exitCode: 0, standardOutput: "", standardError: "")
  var error: Error?
  var reply: String?
  private(set) var requests: [CLIProcessRequest] = []

  func run(_ request: CLIProcessRequest) async throws -> CLIProcessResult {
    requests.append(request)
    if let error { throw error }
    // Codex writes its reply to the file named after --output-last-message.
    if let reply, let index = request.arguments.firstIndex(of: "--output-last-message") {
      try reply.write(toFile: request.arguments[index + 1], atomically: true, encoding: .utf8)
    }
    return result
  }
}

private func output(_ cli: AgentCLI, exitCode: Int32 = 0, stdout: String = "", stderr: String = "", reply: String? = nil)
  -> AgentOutcome
{
  cli.outcome(
    of: CLIProcessResult(exitCode: exitCode, standardOutput: stdout, standardError: stderr),
    lastMessage: reply)
}

private func claudeJSON(_ structured: String, isError: Bool = false) -> String {
  #"{"type":"result","is_error":\#(isError),"result":"boom","structured_output":\#(structured)}"#
}

private final class PathItem: CatalogEntity, @unchecked Sendable {
  init(_ path: String) {
    super.init(id: "file.\(path)", title: (path as NSString).lastPathComponent, path: path)
    typeID = .file
  }
}

@MainActor
final class AgentExtensionTests: XCTestCase {
  private let home = "/Users/test"

  private func run(_ cli: AgentCLI = .claude, runner: StubRunner, paths: [String] = [], found: Bool = true)
    -> AgentRun
  {
    var run = AgentRun(request: "What's my macOS version?", paths: paths, cli: cli)
    run.runner = runner
    run.executable = { found ? "/opt/homebrew/bin/\($0.executableName)" : nil }
    run.home = home
    return run
  }

  // MARK: Declaration

  func testDeclarationIsValid() throws {
    let declaration = try XCTUnwrap(
      try AgentExtension(bundle: Bundle(for: AgentExtension.self)).declaration)
    try declaration.validate()
    XCTAssertEqual(declaration.compatibility?.minTuna, "0.96")
    XCTAssertEqual(declaration.compatibility?.minTunaKit, "1.22.0")
    XCTAssertEqual(declaration.catalogs.map(\.id), ["agent.commands"])
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["agent.actions"])
    XCTAssertEqual(AgentSettings.cli.defaultValue, "claude")
    XCTAssertEqual(AgentSettings.cli.options.map(\.value), ["claude", "codex", "antigravity"])
  }

  func testCommandsCatalogOffersOnlyAskAgent() {
    let catalog = AgentCommandsCatalog(
      definition: CatalogDefinition(
        identifier: "agent.commands", name: "Agent", enabledByDefault: true, settings: []))
    XCTAssertEqual(catalog.objects.map(\.id), ["agent.ask"])
    XCTAssertEqual(catalog.objects.first?.typeID, .searchCatalogEntry)
  }

  // MARK: Arguments

  func testPromptLeadsWithTheContractAndListsPaths() {
    let prompt = AgentCLI.prompt("--help", paths: ["/a/b.pdf", "/c"])
    XCTAssertTrue(prompt.hasPrefix("You were started from a launcher"))
    XCTAssertTrue(prompt.contains("Request:\n--help"))
    XCTAssertTrue(prompt.hasSuffix("Selected files and folders:\n- /a/b.pdf\n- /c"))
    XCTAssertFalse(AgentCLI.prompt("hi", paths: []).contains("Selected files"))
  }

  func testEachCLIRunsUnattendedWithAStructuredReply() {
    let claude = AgentCLI.claude.arguments(
      prompt: "P", extraDirectories: ["/Volumes/X"], schemaFile: "/s", outputFile: "/o")
    XCTAssertEqual(Array(claude.prefix(4)), ["-p", "P", "--add-dir", "/Volumes/X"])
    XCTAssertTrue(claude.contains(AgentCLI.outcomeSchema))
    XCTAssertEqual(claude.firstIndex(of: "auto"), claude.firstIndex(of: "--permission-mode").map { $0 + 1 })
    XCTAssertTrue(claude.contains("--no-session-persistence"))
    XCTAssertFalse(claude.contains("bypassPermissions"))

    let codex = AgentCLI.codex.arguments(
      prompt: "P", extraDirectories: [], schemaFile: "/s", outputFile: "/o")
    XCTAssertEqual(codex.first, "exec")
    XCTAssertEqual(codex.last, "P")
    XCTAssertTrue(codex.contains("--approve-for-me"))
    XCTAssertTrue(codex.contains("--ephemeral"))
    XCTAssertEqual(codex[codex.firstIndex(of: "--output-schema")! + 1], "/s")
    XCTAssertEqual(codex[codex.firstIndex(of: "--output-last-message")! + 1], "/o")
    XCTAssertFalse(codex.contains { $0.contains("dangerously") })

    let agy = AgentCLI.antigravity.arguments(
      prompt: "P", extraDirectories: ["/Volumes/X"], schemaFile: "/s", outputFile: "/o")
    XCTAssertEqual(Array(agy.prefix(2)), ["-p", "P"])
    XCTAssertTrue(agy.contains("--sandbox"))
    XCTAssertTrue(agy.contains("600s"))
    XCTAssertEqual(Array(agy.suffix(2)), ["--add-dir", "/Volumes/X"])
    XCTAssertFalse(agy.contains { $0.contains("dangerously") })
  }

  func testOnlyFoldersOutsideHomeAreAdded() {
    let directories = AgentCLI.extraDirectories(
      for: ["/Users/test/Downloads/a.pdf", "/Users/testing/b.txt", "/Volumes/X/c.txt", "/Volumes/X/d.txt"],
      home: home)
    XCTAssertEqual(directories, ["/Users/testing", "/Volumes/X"])
  }

  func testCLIIsFoundOnTunasPathThenInTheUsualFolders() {
    let onPath = AgentCLI.codex.locate(path: "/custom/bin:relative", home: home) {
      $0 == "/custom/bin/codex" || $0 == "/opt/homebrew/bin/codex"
    }
    XCTAssertEqual(onPath, "/custom/bin/codex")
    let fallback = AgentCLI.antigravity.locate(path: nil, home: home) { $0 == "/Users/test/.local/bin/agy" }
    XCTAssertEqual(fallback, "/Users/test/.local/bin/agy")
    XCTAssertNil(AgentCLI.claude.locate(path: "/x", home: home) { _ in false })
  }

  // MARK: Outcomes

  func testClaudeOutcomes() {
    XCTAssertEqual(output(.claude, stdout: claudeJSON(#"{"outcome":"done","message":"ok"}"#)), .done)
    XCTAssertEqual(
      output(.claude, stdout: claudeJSON(#"{"outcome":"answer","message":" 27.2\n"}"#)), .answer("27.2"))
    XCTAssertEqual(
      output(.claude, stdout: claudeJSON(#"{"outcome":"failed","message":"No such folder"}"#)),
      .failed("No such folder"))
    XCTAssertEqual(
      output(.claude, stdout: claudeJSON(#"{"outcome":"done","message":""}"#, isError: true)), .failed("boom"))
  }

  func testCodexReadsItsReplyFile() {
    XCTAssertEqual(output(.codex, reply: #"{"outcome":"done","message":""}"#), .done)
    XCTAssertEqual(output(.codex, reply: #"{"outcome":"answer","message":"7 files"}"#), .answer("7 files"))
    guard case .failed = output(.codex, reply: nil) else { return XCTFail("A missing reply must fail") }
  }

  func testAntigravityNeedsSuccessStatus() {
    let reply = #"{"outcome":"answer","message":"27.2"}"#
    XCTAssertEqual(
      output(.antigravity, stdout: #"{"status":"SUCCESS","structured_output":\#(reply)}"#), .answer("27.2"))
    XCTAssertEqual(
      output(.antigravity, stdout: #"{"status":"CANCELLED","structured_output":\#(reply)}"#),
      .failed("Antigravity stopped with status CANCELLED."))
  }

  /// Nothing unexpected may turn into a silent "Done".
  func testUnexpectedRepliesFail() {
    for stdout in [
      "", "not json", claudeJSON("null"), claudeJSON(#"{"outcome":"maybe","message":"x"}"#),
      claudeJSON(#"{"outcome":"done"}"#),
    ] {
      guard case .failed = output(.claude, stdout: stdout) else {
        return XCTFail("Expected a failure for \(stdout)")
      }
    }
    XCTAssertEqual(
      output(.claude, stdout: claudeJSON(#"{"outcome":"answer","message":"  "}"#)),
      .failed("The agent returned an empty answer."))
    XCTAssertEqual(
      output(.claude, exitCode: 1, stdout: claudeJSON(#"{"outcome":"done","message":""}"#), stderr: "Not logged in\n"),
      .failed("Claude Code exited with code 1. Not logged in"))
  }

  // MARK: Runs

  func testRunStartsInHomeWithEmptyInputAndATimeout() async throws {
    let runner = StubRunner()
    runner.result = CLIProcessResult(
      exitCode: 0, standardOutput: claudeJSON(#"{"outcome":"answer","message":"27.2"}"#), standardError: "")
    let outcome = await run(runner: runner).perform()
    XCTAssertEqual(outcome, .answer("27.2"))
    let request = try XCTUnwrap(runner.requests.first)
    XCTAssertEqual(request.executablePath, "/opt/homebrew/bin/claude")
    XCTAssertEqual(request.currentDirectoryPath, home)
    XCTAssertEqual(request.standardInput, Data())
    XCTAssertEqual(request.timeout, 600)
  }

  func testCodexRunReadsTheReplyAndCleansUp() async throws {
    let runner = StubRunner()
    runner.reply = #"{"outcome":"done","message":""}"#
    let outcome = await run(.codex, runner: runner).perform()
    XCTAssertEqual(outcome, .done)
    let arguments = try XCTUnwrap(runner.requests.first?.arguments)
    let schema = arguments[arguments.firstIndex(of: "--output-schema")! + 1]
    XCTAssertFalse(FileManager.default.fileExists(atPath: schema), "The run's files must be removed")
  }

  func testMissingCLISaysWhereItLooked() async {
    let runner = StubRunner()
    guard case .failed(let reason) = await run(.antigravity, runner: runner, found: false).perform() else {
      return XCTFail("Expected a failure")
    }
    XCTAssertTrue(reason.hasPrefix("Antigravity (agy) isn't installed. Looked in"))
    XCTAssertTrue(runner.requests.isEmpty)
  }

  func testTimeoutAndCancellationFail() async {
    let runner = StubRunner()
    runner.error = CLIProcessError.timedOut(command: "claude", timeout: 600)
    guard case .failed(let timedOut) = await run(runner: runner).perform() else { return XCTFail() }
    XCTAssertTrue(timedOut.contains("didn't finish within 10 minutes"))
    runner.error = CLIProcessError.cancelled(command: "claude")
    let cancelled = await run(runner: runner).perform()
    XCTAssertEqual(cancelled, .failed("Cancelled. Some of the work may already be done."))
  }

  private final class Delivered: @unchecked Sendable {
    var banners = 0
    var staged: [String] = []
  }

  private func complete(_ stdout: String, exitCode: Int32 = 0, stderr: String = "") async
    -> (CommandTaskCompletion, Delivered)
  {
    let runner = StubRunner()
    runner.result = CLIProcessResult(exitCode: exitCode, standardOutput: stdout, standardError: stderr)
    let delivered = Delivered()
    var agent = run(runner: runner)
    agent.announceDone = { delivered.banners += 1 }
    agent.stageText = { delivered.staged.append($0) }
    return (await agent.complete(), delivered)
  }

  func testDoneShowsOnlyTheBanner() async {
    let (completion, delivered) = await complete(claudeJSON(#"{"outcome":"done","message":"ok"}"#))
    guard case .successWithoutResult = completion.disposition else { return XCTFail() }
    XCTAssertEqual(delivered.banners, 1)
    XCTAssertEqual(delivered.staged, [])
  }

  func testAnAnswerComesBackIntoTunaAsText() async {
    let (completion, delivered) = await complete(
      claudeJSON(#"{"outcome":"answer","message":"27.2\nSequoia"}"#))
    guard case .successWithoutResult = completion.disposition else {
      return XCTFail("Nothing may stay on the Shelf")
    }
    XCTAssertEqual(delivered.staged, ["27.2\nSequoia"])
    XCTAssertEqual(delivered.banners, 0)
  }

  func testAFailureComesBackIntoTunaWithItsReason() async {
    let (completion, delivered) = await complete("", exitCode: 2, stderr: "bad flag")
    guard case .successWithoutResult = completion.disposition else { return XCTFail() }
    XCTAssertEqual(delivered.staged, ["Agent couldn't do it: Claude Code exited with code 2. bad flag"])
    XCTAssertEqual(delivered.banners, 0)
  }

  func testStageLinkEncodesEveryReservedCharacter() throws {
    let url = try XCTUnwrap(AgentStage.url(for: "a & b=c+d?\n#ü /x"))
    XCTAssertEqual(
      url.absoluteString, "tuna://stage?subject=text%3Aa%20%26%20b%3Dc%2Bd%3F%0A%23%C3%BC%20%2Fx")
    let subject = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first
    XCTAssertEqual(subject?.name, "subject")
    XCTAssertEqual(subject?.value, "text:a & b=c+d?\n#ü /x")
  }

  func testShelfTitleIsTheRequestStart() {
    XCTAssertEqual(AgentRun(request: "Rename\nmore", paths: [], cli: .claude).title, "Agent: Rename")
    let long = String(repeating: "a", count: 70)
    XCTAssertEqual(AgentRun(request: long, paths: [], cli: .claude).title, "Agent: " + String(repeating: "a", count: 60) + "…")
  }

  // MARK: Grammar

  private var recorded: [(String, [String])] = []

  private func catalog() -> AgentActionsCatalog {
    AgentActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "agent.actions", name: "Agent Actions")
    ) { [unowned self] request, paths in
      recorded.append((request, paths))
      return AgentRun(request: request, paths: paths, cli: .claude)
    }
  }

  private func action(_ id: String, in catalog: AgentActionsCatalog) throws -> PredicateAwareAction {
    try XCTUnwrap(catalog.actions.first { $0.id == id } as? PredicateAwareAction)
  }

  func testActionsAndTheirSubjects() throws {
    let catalog = catalog()
    XCTAssertEqual(catalog.actions.map(\.id), ["ask", "ask-text", "ask-about"])
    XCTAssertEqual(catalog.actions.map(\.title), ["Ask Agent", "Ask…", "Ask Agent About…"])
    XCTAssertTrue(catalog.actions.allSatisfy { $0.executionPolicy == .dismiss })
    XCTAssertEqual(try action("ask", in: catalog).targetRequirement, .none)
    XCTAssertEqual(try action("ask-text", in: catalog).targetRequirement, .required)
    XCTAssertNil(try action("ask-text", in: catalog).targetTextSeedProvider, "Never seeded from the clipboard")
    XCTAssertEqual(try action("ask-about", in: catalog).supportedSubjectTypes, [.file, .directory])
    XCTAssertTrue(AgentCommandItem().allowsAction(try action("ask-text", in: catalog), catalogIdentifier: "agent.actions"))
    XCTAssertFalse(AgentCommandItem().allowsAction(try action("ask", in: catalog), catalogIdentifier: "agent.actions"))
  }

  func testTextFirstStartsAShelfTask() async throws {
    let ask = try action("ask", in: catalog())
    guard case .background(let task) = await ask.callback(TextSnippetItem(text: "  Empty the trash \n"), nil) else {
      return XCTFail("Expected a Shelf task")
    }
    XCTAssertEqual(task.routing, .shelf)
    XCTAssertEqual(task.title, "Agent: Empty the trash")
    XCTAssertEqual(recorded.map(\.0), ["Empty the trash"])
    XCTAssertEqual(ask.subjectPredicate?(TextSnippetItem(text: " \n")), false)
  }

  func testCommandFirstUsesTheTypedText() async throws {
    let askText = try action("ask-text", in: catalog())
    guard case .background = await askText.callback(AgentCommandItem(), TextSnippetItem(text: "Hi")) else {
      return XCTFail("Expected a Shelf task")
    }
    guard case .failure = await askText.callback(AgentCommandItem(), TextSnippetItem(text: " ")) else {
      return XCTFail("Empty text must not start a run")
    }
    XCTAssertEqual(recorded.map(\.0), ["Hi"])
  }

  func testFilesFirstPassesEverySelectedPathOnce() async throws {
    let askAbout = try action("ask-about", in: catalog())
    let batch = try XCTUnwrap(askAbout.batchCallback)
    let subjects: [CatalogItem] = [PathItem("/a/x.pdf"), PathItem("/b"), PathItem("/a/x.pdf")]
    guard case .background = await batch(subjects, TextSnippetItem(text: "Summarize")) else {
      return XCTFail("Expected a Shelf task")
    }
    XCTAssertEqual(recorded.first?.0, "Summarize")
    XCTAssertEqual(recorded.first?.1, ["/a/x.pdf", "/b"])
    XCTAssertEqual(askAbout.subjectPredicate?(TextSnippetItem(text: "x")), false)
  }
}

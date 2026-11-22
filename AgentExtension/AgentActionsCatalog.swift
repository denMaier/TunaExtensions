import Foundation
import TunaKit

/// Text first: typed text → Ask Agent.
/// Command first: Ask Agent → Ask… → typed text.
/// Files first: files or folders → Ask Agent About… → typed text.
/// Every run is a Shelf task, so Tuna hides while the agent works.
public final class AgentActionsCatalog: ActionCatalog {
  nonisolated static let ask = "ask"
  nonisolated static let askText = "ask-text"
  nonisolated static let askAbout = "ask-about"

  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = [
    makeAsk(), makeAskText(), makeAskAbout(),
  ]

  /// Builds the run for a request and its selected paths.
  private let makeRun: @MainActor @Sendable (String, [String]) -> AgentRun

  public required convenience init(definition: ActionCatalogDefinition) {
    self.init(definition: definition) { request, paths in
      AgentRun(request: request, paths: paths, cli: AgentSettings.selectedCLI)
    }
  }

  init(
    definition: ActionCatalogDefinition,
    makeRun: @escaping @MainActor @Sendable (String, [String]) -> AgentRun
  ) {
    identifier = definition.identifier
    name = definition.name
    self.makeRun = makeRun
  }

  private func makeAsk() -> CatalogAction {
    let makeRun = makeRun
    let action = PredicateAwareAction(id: Self.ask, title: "Ask Agent") { subject, _ in
      Self.start(Self.text(subject), paths: [], makeRun: makeRun)
    }
    action.systemSymbolName = "sparkles"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = { Self.text($0) != nil }
    action.executionPolicy = .dismiss
    return action
  }

  private func makeAskText() -> CatalogAction {
    let makeRun = makeRun
    let action = PredicateAwareAction(id: Self.askText, title: "Ask…") { subject, target in
      guard subject is AgentCommandItem else { return .failure("Choose Ask Agent first") }
      return Self.start(Self.text(target), paths: [], makeRun: makeRun)
    }
    action.systemSymbolName = "sparkles"
    action.supportedSubjectTypes = [.searchCatalogEntry]
    action.subjectPredicate = { $0 is AgentCommandItem }
    action.targetRequirement = .required
    action.allowedTargetTypes = [.textSnippet]
    action.targetPredicate = { Self.text($0) != nil }
    // No seed: a request runs tasks, so it is never taken from the clipboard.
    action.executionPolicy = .dismiss
    return action
  }

  private func makeAskAbout() -> CatalogAction {
    let makeRun = makeRun
    let action = PredicateAwareAction(id: Self.askAbout, title: "Ask Agent About…") {
      subject, target in
      Self.start(Self.text(target), paths: Self.paths([subject]), makeRun: makeRun)
    }
    action.batchCallback = { subjects, target in
      Self.start(Self.text(target), paths: Self.paths(subjects), makeRun: makeRun)
    }
    action.systemSymbolName = "sparkles"
    action.supportedSubjectTypes = [.file, .directory]
    action.subjectPredicate = { !Self.paths([$0].compactMap { $0 }).isEmpty }
    action.targetRequirement = .required
    action.allowedTargetTypes = [.textSnippet]
    action.targetPredicate = { Self.text($0) != nil }
    action.executionPolicy = .dismiss
    return action
  }

  @MainActor
  private static func start(
    _ request: String?, paths: [String],
    makeRun: @MainActor @Sendable (String, [String]) -> AgentRun
  ) -> ActionResult {
    guard let request else { return .failure("Type a question or task first") }
    return .background(makeRun(request, paths).task)
  }

  static func text(_ item: CatalogItem?) -> String? {
    let text = item?.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
  }

  /// Local paths of the selected files and folders, without duplicates.
  static func paths(_ items: [CatalogItem]) -> [String] {
    var paths: [String] = []
    for item in items {
      guard let path = (item as? CatalogEntity)?.path, path.hasPrefix("/"), !paths.contains(path)
      else { continue }
      paths.append(path)
    }
    return paths
  }
}

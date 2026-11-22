import Foundation
import TunaKit

@objc(AgentExtension)
public final class AgentExtension: Extension {
  static let commandsCatalogID = "agent.commands"
  nonisolated static let actionsCatalogID = "agent.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Agent",
        author: "Denis Maier",
        description:
          "Hand a question or task to Claude Code, Codex, or Antigravity. A finished task shows a short banner; answers come back into Tuna as text.",
        iconName: "sparkles"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: AgentSettings.definitions,
      catalogs: [
        // Only the Ask Agent command, for starting with the command and typing the request second.
        CatalogDeclaration(
          id: Self.commandsCatalogID,
          type: AgentCommandsCatalog.self,
          name: "Agent",
          presentation: .source,
          description: "Ask Agent, for typing a question or task after choosing the command",
          enabledByDefault: true,
          initialGlobalScope: .all
        )
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogID,
          type: AgentActionsCatalog.self,
          name: "Agent Actions"
        )
      ]
    )
  }
}

enum AgentSettings {
  static let cli = CatalogSettingDefinition(
    key: "AgentCLI",
    type: .string,
    label: "Agent",
    defaultValue: AgentCLI.claude.rawValue,
    description:
      "The command-line agent that runs your requests. It must be installed and signed in.",
    options: AgentCLI.allCases.map { .init(value: $0.rawValue, label: $0.displayName) }
  )

  static let definitions = [cli]

  static var selectedCLI: AgentCLI {
    AgentCLI(rawValue: store.stringValue(for: cli)) ?? .claude
  }

  private static var store: CatalogSettingStore {
    let bundle = Bundle(for: AgentExtension.self)
    return CatalogSettingStore(
      catalogIdentifier: bundle.bundleIdentifier ?? "com.brnbw.tuna.plugins.agent")
  }
}

@MainActor
public final class AgentCommandsCatalog: Catalog {
  public let identifier: String
  public let name: String
  public let objects: [CatalogItem] = [AgentCommandItem()]

  public init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  public func scan() async { reportScanFinished() }
}

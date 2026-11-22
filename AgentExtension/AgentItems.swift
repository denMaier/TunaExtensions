import AppKit
import Foundation
import TunaKit

/// "Ask Agent": the subject when you start with the command and type the request second.
final class AgentCommandItem: CatalogEntity, ActionFilteringProviding, @unchecked Sendable {
  init() {
    super.init(id: "agent.ask", title: "Ask Agent", path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? { "Type a question or task for \(AgentSettings.selectedCLI.displayName)" }
  override var searchKeys: [String] { [title, "Agent", AgentSettings.selectedCLI.displayName] }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: "sparkles", color: .purple, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    catalogIdentifier == AgentExtension.actionsCatalogID
      && action.id == AgentActionsCatalog.askText
  }
}

/// A small banner near the bottom of the screen. TunaKit has no notice API, so this is a plain
/// non-activating panel that ignores the mouse and goes away on its own.
@MainActor
enum AgentNotice {
  private static var panel: NSPanel?

  static func show(_ text: String, for duration: Duration = .seconds(2)) {
    panel?.orderOut(nil)
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.frame.size = label.fittingSize
    let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 24)
    label.frame.origin = NSPoint(x: 20, y: 12)
    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .hudWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.addSubview(label)
    let notice = NSPanel(
      contentRect: background.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    notice.isOpaque = false
    notice.backgroundColor = .clear
    notice.level = .statusBar
    notice.ignoresMouseEvents = true
    notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    notice.contentView = background
    if let screen = NSScreen.main?.visibleFrame {
      notice.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 96))
    }
    notice.orderFrontRegardless()
    panel = notice
    Task { @MainActor in
      try? await Task.sleep(for: duration)
      notice.orderOut(nil)
      if panel === notice { panel = nil }
    }
  }
}

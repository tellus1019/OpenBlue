import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
  private(set) var window: NSWindow?
  private let makeContent: () -> NSView

  init(makeContent: @escaping () -> NSView) {
    self.makeContent = makeContent
  }

  func show() {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "OpenBlue"
      window.identifier = NSUserInterfaceItemIdentifier("main")
      window.isReleasedWhenClosed = false
      // Login and ordinary launches must never restore a processing window.
      window.isRestorable = false
      window.contentView = makeContent()
      window.delegate = self
      window.center()
      self.window = window
    }
    NSApp.setActivationPolicy(.regular)
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    return false
  }
}

@MainActor
protocol LoginItemService {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

@MainActor
private struct MainAppLoginItem: LoginItemService {
  var status: SMAppService.Status { SMAppService.mainApp.status }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemModel: ObservableObject {
  @Published private(set) var status: SMAppService.Status = .notRegistered
  @Published private(set) var errorMessage: String?
  private let service: any LoginItemService

  init(service: (any LoginItemService)? = nil) {
    self.service = service ?? MainAppLoginItem()
    refresh()
  }

  var isRegistered: Bool { status == .enabled || status == .requiresApproval }

  func refresh() { status = service.status }

  func setEnabled(_ enabled: Bool) {
    refresh()
    errorMessage = nil
    guard enabled != isRegistered else { return }
    do {
      if enabled { try service.register() } else { try service.unregister() }
    } catch {
      errorMessage = "Could not change Launch at login: \(error.localizedDescription)"
    }
    // The system is authoritative, including changes made in System Settings.
    refresh()
  }
}

struct StartupSettings: View {
  @ObservedObject var loginItem: LoginItemModel

  var body: some View {
    GroupBox("Startup") {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Launch at login", isOn: Binding(
          get: { loginItem.isRegistered }, set: { loginItem.setEnabled($0) }))
        Text("OpenBlue starts enabled in the menu bar, without opening a window.")
          .font(.caption).foregroundStyle(.secondary)
        if loginItem.status == .requiresApproval {
          Text("Allow OpenBlue in System Settings to finish enabling launch at login.")
            .font(.caption)
          Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        } else if loginItem.status == .notFound {
          Text("OpenBlue could not be located as a login item. Run the installed app from Applications.")
            .font(.caption).foregroundStyle(.red)
        }
        if let error = loginItem.errorMessage {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear { loginItem.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in loginItem.refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      _ in loginItem.refresh()
    }
  }
}

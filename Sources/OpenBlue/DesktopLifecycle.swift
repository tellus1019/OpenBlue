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
        contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
      window.title = "OpenBlue"
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      let titlebarHeight = NSTitlebarAccessoryViewController()
      titlebarHeight.layoutAttribute = .bottom
      titlebarHeight.view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 20))
      window.addTitlebarAccessoryViewController(titlebarHeight)
      window.minSize = NSSize(width: 1000, height: 700)
      window.tabbingMode = .disallowed
      window.identifier = NSUserInterfaceItemIdentifier("main")
      window.isReleasedWhenClosed = false
      // Login and ordinary launches must never restore a processing window.
      window.isRestorable = false
      window.contentView = makeContent()
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      let nativeTitleHeight = window.frame.height - window.contentLayoutRect.height - titlebarHeight.view.frame.height
      titlebarHeight.view.setFrameSize(NSSize(width: titlebarHeight.view.frame.width,
        height: max(0, 52 - nativeTitleHeight)))
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      window.delegate = self
      window.center()
      self.window = window
    }
    NSApp.setActivationPolicy(.regular)
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)
    if let window { positionWindowButtons(window) }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func positionWindowButtons(_ window: NSWindow) {
    for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
      guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
      let origin = parent.convert(NSPoint(x: 18 + CGFloat(index) * 20,
        y: window.frame.height - 26 - button.frame.height / 2), from: nil)
      button.setFrameOrigin(origin)
    }
  }
  func windowDidResize(_ notification: Notification) {
    if let window { positionWindowButtons(window) }
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

struct OpenBlueSettings: View {
  @ObservedObject var model: AudioModel
  @ObservedObject var loginItem: LoginItemModel
  private func heading(_ text: String) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.settingsError != nil {
        VStack(alignment: .leading, spacing: 8) {
          Text("Settings couldn’t be loaded").font(.system(size: 13, weight: .semibold))
          Text("settings.json is invalid or from a newer version. It has been kept unchanged and won’t be overwritten. Restore a backup, or open the settings folder to keep a copy.")
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Restore…") { model.restorePresets() }
            Button("Settings Folder") { model.showSettingsFolder() }
          }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      }
      VStack(alignment: .leading, spacing: 8) {
        heading("Startup")
        HStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Launch at login").font(.system(size: 13, weight: .medium))
            Text("Start in the menu bar without opening a window.").font(.system(size: 11.5)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Toggle("Launch at login", isOn: Binding(get: { loginItem.isRegistered }, set: { loginItem.setEnabled($0) }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(14).background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UIStyle.line))
        if loginItem.isRegistered {
          Text("macOS may ask you to approve OpenBlue in Login Items settings.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if loginItem.status == .requiresApproval {
          Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
        } else if loginItem.status == .notFound {
          Text("OpenBlue could not be located as a login item. Run the installed app from Applications.").font(.system(size: 11)).foregroundStyle(.red)
        }
        if let error = loginItem.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
      }
      VStack(alignment: .leading, spacing: 8) {
        heading("Preset library")
        VStack(spacing: 0) {
          libraryRow("Back Up", detail: "Save your presets and settings to a file.", button: "Back Up…", action: model.exportPresets)
            .disabled(model.settingsError != nil)
          Divider().padding(.horizontal, 14)
          libraryRow("Restore", detail: "Replaces the library after confirmation. Audio is turned off until you enable it again.", button: "Restore…", action: model.restorePresets)
        }.background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UIStyle.line))
      }
    }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 22).frame(width: 520).fixedSize(horizontal: false, vertical: true).background(UIStyle.window)
      .onAppear { loginItem.refresh() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in loginItem.refresh() }
      .alert("Presets", isPresented: Binding(get: { model.presetMessage != nil }, set: { if !$0 { model.presetMessage = nil } })) {
        Button("OK") { model.presetMessage = nil }
      } message: { Text(model.presetMessage ?? "") }
  }
  private func libraryRow(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button(button, action: action).controlSize(.small)
    }.padding(14)
  }
}

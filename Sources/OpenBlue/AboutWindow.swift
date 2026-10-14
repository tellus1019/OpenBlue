import AppKit
import SwiftUI

struct LicenseDocument: Identifiable {
  let id: String
  let title: String
  let text: String

  static func bundled(in bundle: Bundle = .main) throws -> [LicenseDocument] {
    let entries = [
      ("Acknowledgements", "Third-Party Software and Models"),
      ("DPDFNet-Apache-2.0", "DPDFNet — Apache License 2.0"),
      ("CoreML-Conversion-MIT", "Core ML Conversion — MIT License"),
      ("CoreML-Conversion-NOTICE", "Core ML Conversion — Notices"),
    ]
    return try entries.map { name, title in
      guard let url = bundle.url(forResource: name, withExtension: "txt",
                                 subdirectory: "ThirdPartyLicenses") else {
        throw CocoaError(.fileNoSuchFile)
      }
      return LicenseDocument(id: name, title: title,
                             text: try String(contentsOf: url, encoding: .utf8))
    }
  }
}

@MainActor
final class AboutWindowController: NSObject {
  private var window: NSPanel?

  func show() {
    if window == nil {
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      panel.title = "About OpenBlue"
      panel.isReleasedWhenClosed = false
      panel.isRestorable = false

      let content = AboutContentView()
      let icon = NSImageView(image: NSApplication.shared.applicationIconImage)
      icon.imageScaling = .scaleProportionallyUpOrDown
      icon.setAccessibilityElement(false)
      let title = NSTextField(labelWithString: "OpenBlue")
      title.font = .boldSystemFont(ofSize: 22)
      let info = Bundle.main.infoDictionary ?? [:]
      let version = NSTextField(labelWithString:
        "Version \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))")
      version.textColor = .secondaryLabelColor
      let description = NSTextField(labelWithString: "Local microphone processing.")
      let licenses = NSButton(title: "Third-Party Licenses", target: self,
                              action: #selector(showLicenses))
      licenses.bezelStyle = .rounded
      let stack = NSStackView(views: [icon, title, version, description, licenses])
      stack.orientation = .vertical
      stack.alignment = .centerX
      stack.spacing = 12
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        icon.widthAnchor.constraint(equalToConstant: 72),
        icon.heightAnchor.constraint(equalToConstant: 72),
        stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
      ])
      panel.contentView = content
      panel.center()
      window = panel
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeFirstResponder(nil)
  }

  @objc private func showLicenses() {
    guard let window, window.attachedSheet == nil else { return }
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = "Third-Party Licenses"
    sheet.contentView = NSHostingView(rootView: LicenseView { [weak window, weak sheet] in
      guard let window, let sheet else { return }
      window.endSheet(sheet)
    })
    window.beginSheet(sheet) { [weak window] _ in
      window?.makeFirstResponder(nil)
    }
  }
}

private final class AboutContentView: NSView {
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(nil)
  }
}

private struct LicenseView: View {
  let dismiss: () -> Void
  private let documents = Result { try LicenseDocument.bundled() }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Third-Party Licenses").font(.title2.bold())
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          switch documents {
          case .success(let documents):
            ForEach(documents) { document in
              VStack(alignment: .leading, spacing: 8) {
                Text(document.title).font(.headline)
                Text(verbatim: document.text)
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          case .failure:
            Text("The bundled licenses could not be read. Reinstall OpenBlue to restore its resources.")
              .foregroundStyle(.secondary)
          }
        }.padding(12)
      }.background(.background).border(.separator)
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: 680, height: 500)
  }
}

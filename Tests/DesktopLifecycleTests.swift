import AppKit
import ServiceManagement

@MainActor
private final class TestLoginItem: LoginItemService {
  var status: SMAppService.Status = .notRegistered
  var registrationResult: SMAppService.Status = .enabled
  var failure: Error?
  var registrations = 0
  var removals = 0

  func register() throws {
    registrations += 1
    if let failure { throw failure }
    status = registrationResult
  }

  func unregister() throws {
    removals += 1
    if let failure { throw failure }
    status = .notRegistered
  }
}

@main
struct DesktopLifecycleTests {
  @MainActor static func main() {
    let service = TestLoginItem()
    let login = LoginItemModel(service: service)
    precondition(!login.isRegistered && service.registrations == 0)
    login.setEnabled(true)
    precondition(login.isRegistered && service.registrations == 1)
    login.setEnabled(true)
    precondition(service.registrations == 1)
    login.setEnabled(false)
    precondition(!login.isRegistered && service.removals == 1)

    service.registrationResult = .requiresApproval
    login.setEnabled(true)
    precondition(login.isRegistered && login.status == .requiresApproval)
    service.status = .notRegistered
    login.refresh()
    precondition(!login.isRegistered)
    service.failure = NSError(domain: "DesktopLifecycleTests", code: 1)
    login.setEnabled(true)
    precondition(!login.isRegistered && login.errorMessage != nil)
    service.status = .enabled
    login.setEnabled(false)
    precondition(login.isRegistered && login.errorMessage != nil)
    service.failure = nil
    login.setEnabled(false)
    precondition(!login.isRegistered && login.errorMessage == nil)
    print("Login item state, external changes, approval, and failures passed")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var creations = 0
    let controller = MainWindowController {
      creations += 1
      return NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 760))
    }
    precondition(controller.window == nil && creations == 0)
    precondition(app.activationPolicy() == .accessory)
    controller.show()
    let window = controller.window!
    precondition(window.isVisible && app.activationPolicy() == .regular)
    window.performClose(nil)
    precondition(!window.isVisible && app.activationPolicy() == .accessory)
    controller.show()
    precondition(controller.window === window && creations == 1)
    precondition(window.isVisible && app.activationPolicy() == .regular)
    controller.show()
    precondition(creations == 1)
    window.miniaturize(nil)
    controller.show()
    precondition(!window.isMiniaturized && window.isVisible)
    window.performClose(nil)
    precondition(!window.isVisible && app.activationPolicy() == .accessory)
    print("Lazy window, Dock policy, close, reopen, and minimize recovery passed")
  }
}

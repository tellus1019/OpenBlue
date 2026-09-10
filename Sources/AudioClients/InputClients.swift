import CoreAudio
import Foundation

public struct InputProcess: Equatable, Sendable {
  public let id: AudioObjectID
  public let pid: pid_t
  public let running: Bool
  public let devices: [AudioObjectID]

  public init(id: AudioObjectID, pid: pid_t, running: Bool, devices: [AudioObjectID]) {
    self.id = id
    self.pid = pid
    self.running = running
    self.devices = devices
  }

  public static func consumers(
    in processes: [InputProcess], device: AudioObjectID, excluding pid: pid_t
  ) -> [InputProcess] {
    processes.filter { $0.pid != pid && $0.running && $0.devices.contains(device) }
  }
}

// Apple's AudioHardware.h defines input activity on process objects. Driver
// StartIO/StopIO callbacks are not an application inventory on the target host.
@MainActor public final class InputClients {
  public private(set) var processes: [InputProcess] = []
  public private(set) var error: OSStatus = noErr
  private var listener: AudioObjectPropertyListenerBlock?
  private var observed: [AudioObjectID] = []
  private var changed: (() -> Void)?

  public init() {}

  private static func address(_ selector: AudioObjectPropertySelector,
                              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    throws -> [AudioObjectID] {
    var a = address(selector, scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size)
    guard status == noErr else { throw ReadError(status: status) }
    if size == 0 { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result)
    guard status == noErr else { throw ReadError(status: status) }
    return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }

  private static func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
    throws -> UInt32 {
    var a = address(selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
    guard status == noErr else { throw ReadError(status: status) }
    return value
  }

  private struct ReadError: Error { let status: OSStatus }

  public static func snapshot() throws -> [InputProcess] {
    try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
      .compactMap { id in
        do {
          return try InputProcess(
            id: id, pid: pid_t(bitPattern: scalar(id, kAudioProcessPropertyPID)),
            running: scalar(id, kAudioProcessPropertyIsRunningInput) != 0,
            devices: ids(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput))
        } catch let error as ReadError where error.status == kAudioHardwareBadObjectError {
          // A process can exit between the inventory and its property reads.
          return nil
        }
      }
  }

  private static var processAddresses: [AudioObjectPropertyAddress] {
    [address(kAudioProcessPropertyIsRunningInput),
     address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)]
  }

  public func start(changed: @escaping () -> Void) {
    self.changed = changed
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.reload() }
    }
    self.listener = listener
    var a = Self.address(kAudioHardwarePropertyProcessObjectList)
    error = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
    if error == noErr { reload() } else { changed() }
  }

  public func stop() {
    guard let listener else { return }
    var a = Self.address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
    for id in observed {
      for var a in Self.processAddresses {
        AudioObjectRemovePropertyListenerBlock(id, &a, .main, listener)
      }
    }
    observed = []
    self.listener = nil
    changed = nil
  }

  private func reload() {
    guard let listener else { return }
    do {
      let next = try Self.snapshot()
      let nextIDs = next.map(\.id)
      for id in observed where !nextIDs.contains(id) {
        for var a in Self.processAddresses {
          AudioObjectRemovePropertyListenerBlock(id, &a, .main, listener)
        }
      }
      for id in nextIDs where !observed.contains(id) {
        for var a in Self.processAddresses {
          let status = AudioObjectAddPropertyListenerBlock(id, &a, .main, listener)
          if status != noErr && status != kAudioHardwareBadObjectError {
            throw ReadError(status: status)
          }
        }
      }
      observed = nextIDs
      // Re-read after subscribing so a start/stop during subscription is not lost.
      processes = try Self.snapshot()
      error = noErr
    } catch let failure as ReadError {
      error = failure.status
    } catch {
      self.error = kAudioHardwareUnspecifiedError
    }
    changed?()
  }
}

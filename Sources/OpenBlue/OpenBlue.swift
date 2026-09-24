import AVFoundation
import AppKit
import AudioClients
import AudioCore
import AudioLifecycle
import CoreAudio
import Darwin
import OSLog
import Settings
import SwiftUI

private let consumerSelector: AudioObjectPropertySelector = 0x6f62_636c
private let virtualUID = "org.openblue.virtual-device"

struct AudioDevice: Identifiable, Equatable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let hasInput: Bool
  var isYeti: Bool {
    // The original USB Yeti has this product identity. A Logitech replacement
    // route is not proof of G HUB independent capture and is not selected.
    hasInput && name == "Yeti Stereo Microphone" && uid.hasPrefix("AppleUSBAudioEngine:")
  }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  .init(
    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}
private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
  -> String?
{
  var a = address(selector)
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var result: Unmanaged<CFString>?
  guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result) == noErr,
    let result
  else { return nil }
  return result.takeRetainedValue() as String
}
private func devices() -> [AudioDevice] {
  var a = address(kAudioHardwarePropertyDevices)
  var bytes: UInt32 = 0
  guard
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &bytes)
      == noErr
  else { return [] }
  var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
  guard
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &bytes, &ids)
      == noErr
  else { return [] }
  return ids.prefix(Int(bytes) / MemoryLayout<AudioDeviceID>.size).compactMap { id in
    guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
      let name = stringProperty(id, kAudioObjectPropertyName)
    else { return nil }
    var streams = address(kAudioDevicePropertyStreams)
    streams.mScope = kAudioObjectPropertyScopeInput
    var streamBytes: UInt32 = 0
    let hasInput =
      AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr
      && streamBytes >= MemoryLayout<AudioStreamID>.size
    return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput)
  }
}
private func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
  var a = address(kAudioDevicePropertyNominalSampleRate)
  var size = UInt32(MemoryLayout<Double>.size)
  var rate = Double(0)
  guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &rate) == noErr else { return nil }
  return rate
}

@MainActor final class AudioModel: ObservableObject {
  @Published var settings = AudioSettings()
  @Published var enabled = false
  @Published var status = "Stopped"
  let meterDisplay = MeterDisplay()
  @Published var availableYetis: [AudioDevice] = []
  @Published var settingsError: String?
  @Published var presetMessage: String?
  private var engine: OpaquePointer?
  private var engineInput: AudioDeviceID = 0
  private var engineOutput: AudioDeviceID = 0
  private var observedInput: AudioDeviceID = 0
  private var deviceListener: AudioObjectPropertyListenerBlock?
  private var serviceListener: AudioObjectPropertyListenerBlock?
  private let inputClients = InputClients()
  private var formatListener: AudioObjectPropertyListenerBlock?
  private var retryTask: Task<Void, Never>?
  private var recovery = RecoveryBackoff()
  private var meterTimer: Timer?
  private var readoutTimer: Timer?
  private var healthTimer: Timer?
  private var profileTimer: Timer?
  private var visibleMeterWindows: Set<ObjectIdentifier> = []
  private let callbackProfiling = ProcessInfo.processInfo.environment["OPENBLUE_CALLBACK_PROFILE"] == "1"
  private let nanosecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
  }()
  private var awake = true
  private var failed = false
  private var knownYetiUIDs: Set<String> = []
  private var driverAvailable = false
  private var consumerCount = 0
  private let store: SettingsStore
  private let audioLog = Logger(subsystem: "org.openblue.app", category: "AudioLifecycle")

  init() {
    store = SettingsStore(
      url: FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("OpenBlue/settings.json"))
    do { settings = try store.load() } catch { settingsError = error.localizedDescription }
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.topologyChanged() }
    }
    deviceListener = listener
    var a = address(kAudioHardwarePropertyDevices)
    let result = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
    if result != noErr {
      status = "Device observation failed (\(result))"
      failed = true
    }
    let restarted: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.audioServiceRestarted() }
    }
    serviceListener = restarted
    var service = address(kAudioHardwarePropertyServiceRestarted)
    let serviceResult = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &service, .main, restarted)
    if serviceResult != noErr {
      status = "Audio service observation failed (\(serviceResult))"
      failed = true
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    inputClients.start { [weak self] in self?.inputClientsChanged() }
    refresh()
  }
  private func cancelRetry(reset: Bool) {
    retryTask?.cancel()
    retryTask = nil
    if reset { recovery.reset() }
  }
  private func topologyChanged() {
    cancelRetry(reset: true)
    failed = false
    refresh()
  }
  private func inputClientsChanged() {
    cancelRetry(reset: false)
    refresh()
  }
  private func removeFormatListener() {
    if let formatListener, observedInput != 0 {
      var a = address(kAudioDevicePropertyNominalSampleRate)
      AudioObjectRemovePropertyListenerBlock(observedInput, &a, .main, formatListener)
    }
    observedInput = 0
    formatListener = nil
  }
  private func audioServiceRestarted() {
    audioLog.notice("Core Audio service restarted; rebuilding device and client observation")
    cancelRetry(reset: true)
    stopAudio()
    removeFormatListener()
    inputClients.stop()
    inputClients.start { [weak self] in self?.inputClientsChanged() }
    failed = false
    status = "Audio service restarted · Recovering"
    refresh()
  }
  private func scheduleRecovery(_ operation: String, error: OSStatus) {
    stopAudio()
    guard enabled, awake, settingsError == nil else { return }
    let delay = recovery.nextDelay()
    let attempt = recovery.attempt
    status = String(format: "%@ failed (%d) · Retrying in %.1f seconds", operation, error, delay)
    audioLog.error("\(operation, privacy: .public) failed status=\(error) retry=\(attempt) delay=\(delay, format: .fixed(precision: 1))s")
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.retryTask = nil
      self.refresh()
    }
  }
  @objc private func sleep() {
    awake = false
    cancelRetry(reset: true)
    stopAudio()
    status = "Paused for sleep"
  }
  @objc private func wake() {
    awake = true
    failed = false
    cancelRetry(reset: true)
    audioLog.notice("Mac woke; rebuilding the audio path if it is still requested")
    refresh()
  }
  func save() {
    do {
      try store.save(settings)
      settingsError = nil
    } catch {
      settingsError = error.localizedDescription
      enabled = false
      stopAudio()
    }
    applyProcessing()
  }
  private func applyProcessing() {
    if let engine {
      let applied = settings.dspValues.withUnsafeBufferPointer {
        ob_engine_parameters(engine, $0.baseAddress, UInt32($0.count))
      }
      if !applied {
        settingsError = "Processing settings could not be applied."
        enabled = false
        stopAudio()
      }
    }
  }
  func changePreset(_ change: (inout AudioSettings) throws -> Void) -> Bool {
    guard settingsError == nil else { return false }
    var candidate = settings
    do { try change(&candidate) } catch {
      presetMessage = error.localizedDescription
      return false
    }
    do {
      try store.save(candidate)
      settings = candidate
      applyProcessing()
      return settingsError == nil
    } catch {
      settingsError = error.localizedDescription
      enabled = false
      stopAudio()
      return false
    }
  }
  func showSettingsFolder() {
    NSWorkspace.shared.selectFile(store.url.path, inFileViewerRootedAtPath: store.url.deletingLastPathComponent().path)
  }
  func exportPresets() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "OpenBlue-presets.json"
    panel.title = "Back Up Presets"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try store.exportBackup(settings, to: destination)
      presetMessage = "Preset backup saved."
    } catch { presetMessage = error.localizedDescription }
  }
  func restorePresets() {
    let panel = NSOpenPanel()
    panel.title = "Restore Preset Backup"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let source = panel.url else { return }
    do {
      let candidate = try store.readBackup(from: source)
      let confirmation = NSAlert()
      confirmation.messageText = "Restore \(candidate.presets.count) preset(s)?"
      confirmation.informativeText = "This replaces the current preset library and selection. The current settings file will be preserved in the settings folder. Audio will be disabled; enable it again when ready."
      confirmation.addButton(withTitle: "Restore")
      confirmation.addButton(withTitle: "Cancel")
      guard confirmation.runModal() == .alertFirstButtonReturn else { return }
      let preserved = try store.restore(candidate)
      enabled = false
      stopAudio()
      settings = candidate
      settingsError = nil
      refresh()
      presetMessage = preserved.map { "Presets restored. Previous settings preserved at \($0.path)." }
        ?? "Presets restored."
    } catch { presetMessage = error.localizedDescription }
  }
  func select(_ uid: String) {
    settings.deviceUID = uid
    save()
    refresh()
  }
  func setEnabled(_ value: Bool) {
    enabled = value
    failed = false
    guard value else {
      cancelRetry(reset: true)
      stopAudio()
      status = "Stopped"
      return
    }
    guard settingsError == nil else {
      enabled = false
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: refresh()
    case .notDetermined:
      status = "Waiting for microphone permission"
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if allowed {
            self.refresh()
          } else {
            self.enabled = false
            self.status = "Microphone permission denied"
          }
        }
      }
    default:
      enabled = false
      status = "Allow OpenBlue in System Settings → Privacy & Security → Microphone"
    }
  }
  func refresh() {
    let all = devices()
    availableYetis = all.filter(\.isYeti)
    let output = all.first { $0.uid == virtualUID }
    let nextYetiUIDs = Set(availableYetis.map(\.uid))
    if nextYetiUIDs != knownYetiUIDs {
      audioLog.notice("Yeti device set changed: count=\(nextYetiUIDs.count)")
      knownYetiUIDs = nextYetiUIDs
    }
    if (output != nil) != driverAvailable {
      driverAvailable = output != nil
      audioLog.notice("Virtual microphone availability changed: available=\(self.driverAvailable)")
    }
    guard awake, !failed else {
      stopAudio()
      return
    }
    guard enabled else {
      cancelRetry(reset: true)
      stopAudio()
      status = output == nil ? "Driver is not installed" : "Stopped"
      return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      stopAudio()
      return
    }
    guard let output else {
      cancelRetry(reset: true)
      stopAudio()
      status = "Driver is not installed"
      return
    }
    if settings.deviceUID == nil, availableYetis.count == 1 {
      settings.deviceUID = availableYetis[0].uid
      save()
    }
    guard enabled, settingsError == nil else {
      stopAudio()
      status = "Stopped because settings could not be saved"
      return
    }
    guard let input = availableYetis.first(where: { $0.uid == settings.deviceUID }) else {
      cancelRetry(reset: true)
      stopAudio()
      status = "Connect the original Yeti using the standard USB audio driver"
      return
    }
    if observedInput != input.id {
      removeFormatListener()
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.topologyChanged()
        }
      }
      var a = address(kAudioDevicePropertyNominalSampleRate)
      let code = AudioObjectAddPropertyListenerBlock(input.id, &a, .main, listener)
      guard code == noErr else {
        scheduleRecovery("Yeti format observation", error: code)
        return
      }
      observedInput = input.id
      formatListener = listener
    }
    guard nominalSampleRate(input.id) == 48_000 else {
      cancelRetry(reset: true)
      stopAudio()
      status = "Set the selected Yeti to 48 kHz in Audio MIDI Setup"
      return
    }
    guard inputClients.error == noErr else {
      stopAudio()
      status = "Input client observation failed (\(inputClients.error))"
      return
    }
    let count = InputProcess.consumers(
      in: inputClients.processes, device: output.id, excluding: getpid()).count
    if count != consumerCount {
      consumerCount = count
      audioLog.notice("Virtual microphone input users changed: processes=\(count)")
    }
    guard count > 0 else {
      cancelRetry(reset: true)
      stopAudio()
      status = "Ready · Select OpenBlue as the microphone in another app"
      return
    }
    if engineInput != input.id || engineOutput != output.id { stopAudio() }
    guard retryTask == nil else { return }
    if engine == nil {
      var error: OSStatus = 0
      guard let newEngine = ob_engine_create(input.id, output.id, &error) else {
        scheduleRecovery("Audio setup", error: error)
        return
      }
      let applied = settings.dspValues.withUnsafeBufferPointer {
        ob_engine_parameters(newEngine, $0.baseAddress, UInt32($0.count))
      }
      guard applied else {
        ob_engine_destroy(newEngine)
        failed = true
        status = "Processing settings could not be applied."
        return
      }
      ob_engine_set_profiling(newEngine, callbackProfiling)
      let start = ob_engine_start(newEngine)
      guard start == noErr else {
        ob_engine_destroy(newEngine)
        scheduleRecovery("Audio start", error: start)
        return
      }
      engine = newEngine
      engineInput = input.id
      engineOutput = output.id
      startMonitoring()
      recovery.reset()
      audioLog.info("Audio started: input=\(input.id) output=\(output.id) consumers=\(count) dspDelayFrames=\(OB_DSP_LATENCY)")
    }
    status = "Processing · \(count) external input process(es)"
  }
  func stopAudio() {
    meterTimer?.invalidate(); meterTimer = nil
    readoutTimer?.invalidate(); readoutTimer = nil
    healthTimer?.invalidate(); healthTimer = nil
    profileTimer?.invalidate(); profileTimer = nil
    if let engine {
      let stats = ob_engine_diagnostics(engine)
      audioLog.info("Audio stopping: capture=\(stats.captured_frames) dsp=\(stats.signal.output_frames) render=\(stats.render_frames) error=\(stats.error) underruns=\(stats.signal.underruns) overruns=\(stats.signal.overruns)")
      if callbackProfiling { logCallbackProfile(ob_engine_stats(engine)) }
      ob_engine_destroy(engine)
    }
    engine = nil
    engineInput = 0
    engineOutput = 0
    meterDisplay.clearLevels()
  }

  private func startTimer(_ interval: TimeInterval, selector: Selector) -> Timer {
    let timer = Timer(timeInterval: interval, target: self, selector: selector,
                      userInfo: nil, repeats: true)
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func startMonitoring() {
    // Keep fault detection independent of the display and its visibility.
    healthTimer = startTimer(1.0 / 60.0, selector: #selector(checkHealth(_:)))
    if callbackProfiling {
      profileTimer = startTimer(10, selector: #selector(recordProfile(_:)))
    }
    updateDisplayTimers()
  }

  func setMeterWindowVisible(_ id: ObjectIdentifier, visible: Bool) {
    let wasVisible = !visibleMeterWindows.isEmpty
    if visible { visibleMeterWindows.insert(id) }
    else { visibleMeterWindows.remove(id) }
    if wasVisible != !visibleMeterWindows.isEmpty { updateDisplayTimers() }
  }

  private func updateDisplayTimers() {
    guard engine != nil, !visibleMeterWindows.isEmpty else {
      meterTimer?.invalidate(); meterTimer = nil
      readoutTimer?.invalidate(); readoutTimer = nil
      return
    }
    if meterTimer == nil {
      updateMeters()
      meterTimer = startTimer(MeterDisplay.updateInterval, selector: #selector(meterTick(_:)))
    }
    if readoutTimer == nil {
      updateReadouts()
      readoutTimer = startTimer(0.2, selector: #selector(readoutTick(_:)))
    }
  }

  @objc private func checkHealth(_ timer: Timer) {
    guard let engine else { return }
    let error = ob_engine_error(engine)
    if error != noErr { scheduleRecovery("Audio processing", error: error) }
  }

  @objc private func recordProfile(_ timer: Timer) {
    guard let engine else { return }
    logCallbackProfile(ob_engine_stats(engine))
  }

  @objc private func meterTick(_ timer: Timer) { updateMeters() }
  @objc private func readoutTick(_ timer: Timer) { updateReadouts() }

  private func updateMeters() {
    guard let engine else { return }
    meterDisplay.updateLevels(ob_engine_meters(engine))
  }

  private func updateReadouts() {
    guard let engine else { return }
    meterDisplay.updateReadouts(ob_engine_meters(engine))
    let stats = ob_engine_diagnostics(engine)
    let callbackUS = Double(stats.callback_max_ticks) * nanosecondsPerTick / 1000
    let diagnostics =
      "Underruns: \(stats.signal.underruns)  Overruns: \(stats.signal.overruns)  Clipped: \(stats.signal.clipped_samples)\nFrames: capture \(stats.captured_frames) → DSP \(stats.signal.output_frames) → render \(stats.render_frames)"
      + String(format: "\nMax callback: %.1f µs  Invalid DSP samples: %llu",
               callbackUS, stats.signal.dsp.invalid_samples)
    meterDisplay.diagnostics.update(diagnostics)
  }
  private func logCallbackProfile(_ stats: OBEngineStats) {
    let buckets = withUnsafeBytes(of: stats.output_duration_buckets) {
      Array($0.bindMemory(to: UInt64.self))
    }
    let histogram = buckets.map(String.init).joined(separator: ",")
    audioLog.info(
      "Callback profile: inputCount=\(stats.input_callbacks) inputTicks=\(stats.input_total_ticks) inputMaxTicks=\(stats.input_max_ticks) outputCount=\(stats.output_callbacks) outputTicks=\(stats.output_total_ticks) outputMaxTicks=\(stats.callback_max_ticks) outputBudgetExceeded=\(stats.output_budget_exceeded) outputMinFrames=\(stats.output_min_frames) outputMaxFrames=\(stats.output_max_frames) histogram=\(histogram, privacy: .public)")
  }
}

struct ContentView: View {
  @ObservedObject var model: AudioModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Text("OpenBlue").font(.largeTitle.bold())
          Spacer()
          Text("YETI").foregroundStyle(.secondary)
        }
        Text(model.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let error = model.settingsError {
          Text(error).foregroundStyle(.red)
          Text("The original file is preserved. Restore a known-good backup, or open the settings folder to keep a copy and recover the file. Use a compatible OpenBlue version for newer settings.")
            .font(.caption).foregroundStyle(.secondary)
        }
        PresetControls(model: model)
        if model.availableYetis.count > 1 {
          Picker(
            "Yeti",
            selection: Binding(get: { model.settings.deviceUID ?? "" }, set: { model.select($0) })
          ) {
            ForEach(model.availableYetis) { Text($0.uid).tag($0.uid) }
          }
        }
        Toggle(
          "Enable OpenBlue", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })
        )
        .toggleStyle(.switch).disabled(model.settingsError != nil)
        VStack(alignment: .leading) {
          HStack {
            Text("Input gain")
            Spacer()
            Text(String(format: "%.1f dB", model.settings.gainDB)).monospacedDigit()
          }
          ParameterSlider(
            value: Binding(
              get: { model.settings.gainDB },
              set: {
                model.settings.gainDB = $0
                model.save()
              }), bounds: -24...12, step: 0.5)
          Toggle(
            "Bypass all processing",
            isOn: Binding(
              get: { model.settings.bypass },
              set: {
                model.settings.bypass = $0
                model.save()
              }))
        }.disabled(model.settingsError != nil)
        MeterPanel(display: model.meterDisplay)
        ProcessingEditor(model: model)
        Text(
          "Choose OpenBlue as the input in your recording or meeting app. Keep OpenBlue running. Audio stays on this Mac."
        )
        .font(.callout).foregroundStyle(.secondary)
      }.padding(28)
    }.frame(width: 600, height: 760)
      .background(MeterWindowObserver(model: model))
  }
}

private let mainWindowID = "main"

private struct MainWindowContent: View {
  @Environment(\.openWindow) private var openWindow
  let model: AudioModel
  let delegate: AppDelegate

  var body: some View {
    ContentView(model: model)
      .onAppear {
        delegate.openMainWindow = { [openWindow] in
          openWindow(id: mainWindowID)
          NSApp.activate(ignoringOtherApps: true)
        }
      }
  }
}

private struct ShowMainWindowButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Show OpenBlue") {
      openWindow(id: mainWindowID)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var openMainWindow: (() -> Void)?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard let openMainWindow else { return true }
    openMainWindow()
    return false
  }
}
@main struct OpenBlueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AudioModel()
  init() {
    if CommandLine.arguments.contains("--inspect") {
      let processes = try? InputClients.snapshot()
      let rows = devices().map { device in
        [
          "id": String(device.id), "name": device.name, "uid": device.uid,
          "standardYeti": String(device.isYeti),
          "driverIOCount": device.uid == virtualUID
            ? (stringProperty(device.id, consumerSelector) ?? "unavailable") : "",
          "inputProcesses": device.uid == virtualUID
            ? (processes.map { processes in String(InputProcess.consumers(
              in: processes, device: device.id, excluding: getpid()).count) } ?? "unavailable") : "",
        ]
      }
      if let data = try? JSONSerialization.data(
        withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      exit(0)
    }
  }
  var body: some Scene {
    Window("OpenBlue", id: mainWindowID) {
      MainWindowContent(model: model, delegate: delegate)
    }.windowResizability(.contentSize)
    MenuBarExtra("OpenBlue", systemImage: "mic") {
      Text(model.status)
      Toggle(
        "Enable OpenBlue", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
      ShowMainWindowButton()
      Divider()
      Button("Quit OpenBlue") {
        model.stopAudio()
        NSApp.terminate(nil)
      }
    }
  }
}

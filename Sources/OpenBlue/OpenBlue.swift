import AVFoundation
import AppKit
import AudioClients
import AudioCore
import AudioLifecycle
import CoreAudio
import Darwin
#if DEBUG
import OSLog
#endif
import NeuralNoiseReduction
import Settings
import SwiftUI

// The pointer moves from background preparation to the serialized audio worker.
// The engine is destroyed before this owner releases the model.
private final class AdvancedNRProcessor: @unchecked Sendable {
  let pointer: OpaquePointer
  init(modelPath: String, statePath: String) throws {
    var message = [CChar](repeating: 0, count: 1024)
    guard let pointer = ob_neural_create(modelPath, statePath, &message, message.count) else {
      throw NSError(domain: "OpenBlue.AdvancedNR", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)])
    }
    self.pointer = pointer
  }
  deinit { ob_neural_destroy(pointer) }
  var callbacks: OBAdvancedNR {
    OBAdvancedNR(context: UnsafeMutableRawPointer(pointer), process: { context, input, output in
      ob_neural_process(OpaquePointer(context), input, output)
    }, reset: { context in ob_neural_reset(OpaquePointer(context)) })
  }
}

private actor AdvancedNRLoader {
  static let shared = AdvancedNRLoader()
  func load(modelPath: String, statePath: String) -> Result<AdvancedNRProcessor, Error> {
    // Serialize preparation independently of UI and audio callbacks.
    guard !Task.isCancelled else { return .failure(CancellationError()) }
    return Result { try AdvancedNRProcessor(modelPath: modelPath, statePath: statePath) }
  }
}

#if DEBUG
private let consumerSelector: AudioObjectPropertySelector = 0x6f62_636c
#endif
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
  @Published var copyNotice: String?
  @Published var selectedProcessor = 2
  private var engine: OpaquePointer?
  private var advancedProcessor: AdvancedNRProcessor?
  private var modelLoad: Task<Void, Never>?
  private var engineMode: NoiseReductionMode = .standard
  @Published private var processingLatency: UInt32 = UInt32(OB_STANDARD_NR_LATENCY)
  private var configuredDSPFrames: UInt32 {
    let values = settings.dspValues
    let lookahead = values[Int(OBP_LIMIT_ON.rawValue)] != 0
      ? UInt32(values[Int(OBP_LIMIT_ATTACK.rawValue)] * 48) : 0
    return (settings.noiseReductionMode == .advanced
      ? UInt32(OB_ADVANCED_NR_LATENCY) : UInt32(OB_STANDARD_NR_LATENCY)) + lookahead
  }
  var processingDelayDescription: String {
    if engine == nil && settings.noiseReductionMode == .advanced {
      return String(format: "Advanced processing: %.2f ms DSP delay plus worker buffering. Input buffering and virtual-device latency are additional.",
                    Double(configuredDSPFrames)/48)
    }
    let frames = engine == nil ? configuredDSPFrames : processingLatency
    return String(format: "Processing delay: %.2f ms (%u frames), including bypass. Input buffering and virtual-device latency are additional.",
                  Double(frames)/48, frames)
  }
  var latencyLabel: String {
    if engine == nil && settings.noiseReductionMode == .advanced {
      return String(format: "%.0f ms + buffer", Double(configuredDSPFrames)/48)
    }
    let frames = engine == nil ? configuredDSPFrames : processingLatency
    return String(format: "%.0f ms", Double(frames) / 48)
  }
  var inputDescription: String {
    guard let device = availableYetis.first(where: { $0.uid == settings.deviceUID }),
      let rate = nominalSampleRate(device.id) else { return "Blue Yeti" }
    return String(format: "Blue Yeti · %g kHz", rate / 1000)
  }
  var presentation: AudioStatusPresentation {
    if settingsError != nil { return .init(name: "Settings error", detail: "Open Settings to recover", color: .orange, showsDelay: false) }
    if !enabled { return .init(name: "Stopped", detail: "Capture off", color: Color(nsColor: .disabledControlTextColor), showsDelay: false) }
    if !status.hasPrefix("Processing") && !status.hasPrefix("Ready") {
      let preparing = status.hasPrefix("Preparing")
      if preparing && engine != nil {
        return .init(name: "Preparing", detail: "Standard active until Advanced is ready", color: .orange, showsDelay: true)
      }
      return .init(name: preparing ? "Preparing" : "Attention", detail: status, color: .orange, showsDelay: false)
    }
    let count = "\(consumerCount) " + (consumerCount == 1 ? "process" : "processes")
    if muteBinding.wrappedValue { return .init(name: "Muted", detail: count, color: .red, showsDelay: true) }
    if settings.bypass { return .init(name: "Bypassing", detail: count, color: .yellow, showsDelay: true) }
    if engine != nil { return .init(name: "Processing", detail: count, color: .green, showsDelay: true) }
    return .init(name: "Standby", detail: "No app is using OpenBlue", color: Color(red: 0.56, green: 0.61, blue: 0.69), showsDelay: false)
  }
  private var engineInput: AudioDeviceID = 0
  private var engineOutput: AudioDeviceID = 0
  private var observedInput: AudioDeviceID = 0
  private var deviceListener: AudioObjectPropertyListenerBlock?
  private var serviceListener: AudioObjectPropertyListenerBlock?
  private let inputClients = InputClients()
  private var formatListener: AudioObjectPropertyListenerBlock?
  private var retryTask: Task<Void, Never>?
  private var recovery = RecoveryBackoff()
  private var audioActivity: NSObjectProtocol?
  private var meterTimer: Timer?
  private var readoutTimer: Timer?
  private var healthTimer: Timer?
  #if DEBUG
  private var profileTimer: Timer?
  #endif
  private var visibleMeterWindows: Set<ObjectIdentifier> = []
  #if DEBUG
  private let callbackProfiling = ProcessInfo.processInfo.environment["OPENBLUE_CALLBACK_PROFILE"] == "1"
  #endif
  private var awake = true
  private var failed = false
  private var knownYetiUIDs: Set<String> = []
  private var driverAvailable = false
  @Published private(set) var consumerCount = 0
  private let store: SettingsStore
  #if DEBUG
  private let audioLog = Logger(subsystem: "org.openblue.app", category: "AudioLifecycle")
  #endif

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
    #if DEBUG
    audioLog.notice("Core Audio service restarted; rebuilding device and client observation")
    #endif
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
    #if DEBUG
    let attempt = recovery.attempt
    #endif
    status = String(format: "%@ failed (%d) · Retrying in %.1f seconds", operation, error, delay)
    #if DEBUG
    audioLog.error("\(operation, privacy: .public) failed status=\(error) retry=\(attempt) delay=\(delay, format: .fixed(precision: 1))s")
    #endif
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
    #if DEBUG
    audioLog.notice("Mac woke; rebuilding the audio path if it is still requested")
    #endif
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
    if engineMode != settings.noiseReductionMode {
      if settings.noiseReductionMode == .advanced && advancedProcessor == nil {
        // Keep the current route and its controls alive during first-use preparation.
        if let engine {
          let applied = settings.dspValues.withUnsafeBufferPointer {
            ob_engine_processing(engine, $0.baseAddress, UInt32($0.count), settings.advancedReductionDB)
          }
          guard applied else {
            settingsError = "Processing settings could not be applied."
            enabled = false
            stopAudio()
            return
          }
        }
        prepareAdvancedProcessor()
        return
      }
      stopAudio()
      engineMode = settings.noiseReductionMode
      failed = false
      refresh()
      return
    }
    if let engine {
      if settings.noiseReductionMode == .standard && status.hasPrefix("Preparing") {
        status = "Processing · \(consumerCount) external input process(es)"
      }
      let applied = settings.dspValues.withUnsafeBufferPointer {
        ob_engine_processing(engine, $0.baseAddress, UInt32($0.count), settings.advancedReductionDB)
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
    guard candidate != settings else { return true }
    do {
      try store.save(candidate)
      let source = settings.selectedPreset
      let copied = settings.isFactorySelected && candidate.userPresets.count > settings.userPresets.count
        && (candidate.gainDB != settings.gainDB || candidate.bypass != settings.bypass
          || candidate.processing != settings.processing || candidate.advancedReductionDB != settings.advancedReductionDB)
      settings = candidate
      if copied {
        copyNotice = "\(source.name) is a factory preset, so your change was saved as “\(candidate.selectedPreset.name)”. The original is unchanged."
      } else if source.id != candidate.selectedPresetID { copyNotice = nil }
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
  func enableAtLaunch() {
    // Prepare the model even when no client is using the virtual microphone.
    // This does not open an audio device or request microphone permission.
    prepareAdvancedProcessor()
    guard !failed, settingsError == nil else { return }
    setEnabled(true)
  }
  func refresh() {
    let all = devices()
    availableYetis = all.filter(\.isYeti)
    let output = all.first { $0.uid == virtualUID }
    let nextYetiUIDs = Set(availableYetis.map(\.uid))
    if nextYetiUIDs != knownYetiUIDs {
      #if DEBUG
      audioLog.notice("Yeti device set changed: count=\(nextYetiUIDs.count)")
      #endif
      knownYetiUIDs = nextYetiUIDs
    }
    if (output != nil) != driverAvailable {
      driverAvailable = output != nil
      #if DEBUG
      audioLog.notice("Virtual microphone availability changed: available=\(self.driverAvailable)")
      #endif
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
      #if DEBUG
      audioLog.notice("Virtual microphone input users changed: processes=\(count)")
      #endif
    }
    guard count > 0 else {
      cancelRetry(reset: true)
      stopAudio()
      status = "Ready · Select OpenBlue as the microphone in another app"
      return
    }
    if engine != nil && (engineInput != input.id || engineOutput != output.id) { stopAudio() }
    guard retryTask == nil else { return }
    if engine == nil {
      if settings.noiseReductionMode == .advanced && advancedProcessor == nil {
        prepareAdvancedProcessor()
        guard !failed else { return }
        // A client arriving during cold preparation must still receive audio.
        // Keep the requested method saved; completion switches to Advanced.
        engineMode = .standard
      } else {
        engineMode = settings.noiseReductionMode
      }
      // Virtual microphone processing remains time-sensitive with all windows closed.
      let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "Processing live microphone audio")
      defer {
        if engine == nil { ProcessInfo.processInfo.endActivity(activity) }
      }
      var error: OSStatus = 0
      guard let newEngine = ob_engine_create(input.id, output.id, &error) else {
        scheduleRecovery("Audio setup", error: error)
        return
      }
      let applied = settings.dspValues.withUnsafeBufferPointer {
        ob_engine_processing(newEngine, $0.baseAddress, UInt32($0.count), settings.advancedReductionDB)
      }
      guard applied else {
        ob_engine_destroy(newEngine)
        failed = true
        status = "Processing settings could not be applied."
        return
      }
      if engineMode == .advanced {
        guard let advancedProcessor,
          ob_engine_advanced(newEngine, advancedProcessor.callbacks) else {
          ob_engine_destroy(newEngine)
          failed = true
          status = "Advanced noise reduction could not prepare the audio worker."
          return
        }
      }
      processingLatency = ob_engine_latency(newEngine)
      #if DEBUG
      ob_engine_set_profiling(newEngine, callbackProfiling)
      #endif
      let start = ob_engine_start(newEngine)
      guard start == noErr else {
        ob_engine_destroy(newEngine)
        scheduleRecovery("Audio start", error: start)
        return
      }
      engine = newEngine
      audioActivity = activity
      engineInput = input.id
      engineOutput = output.id
      startMonitoring()
      recovery.reset()
      #if DEBUG
      audioLog.info("Audio started: input=\(input.id) output=\(output.id) consumers=\(count) dspDelayFrames=\(self.processingLatency)")
      #endif
    }
    status = modelLoad != nil && settings.noiseReductionMode == .advanced && engineMode == .standard
      ? "Preparing advanced noise reduction; Standard remains active"
      : "Processing · \(count) external input process(es)"
  }
  private func prepareAdvancedProcessor() {
    guard advancedProcessor == nil else { return }
    if enabled && settings.noiseReductionMode == .advanced && consumerCount > 0 {
      status = engine == nil ? "Preparing advanced noise reduction"
        : "Preparing advanced noise reduction; Standard remains active"
    }
    guard modelLoad == nil else { return }
    guard let modelURL = Bundle.main.url(forResource: "DPDFNet8", withExtension: "mlmodelc"),
      let stateURL = Bundle.main.url(forResource: "initial-state", withExtension: "f32", subdirectory: "DPDFNet") else {
      if settings.noiseReductionMode == .advanced {
        failed = true
        stopAudio()
        status = "Advanced noise reduction resources are missing. Reinstall OpenBlue."
      }
      return
    }
    #if DEBUG
    let started = ContinuousClock.now
    audioLog.info("Advanced noise reduction preparation started")
    #endif
    let modelPath = modelURL.path, statePath = stateURL.path
    modelLoad = Task { [weak self] in
      let result = await AdvancedNRLoader.shared.load(modelPath: modelPath, statePath: statePath)
      guard !Task.isCancelled, let self else { return }
      self.modelLoad = nil
      switch result {
      case .success(let processor):
        self.advancedProcessor = processor
        #if DEBUG
        self.audioLog.info("Advanced noise reduction prepared in \(String(describing: started.duration(to: .now)), privacy: .public)")
        #endif
        // Reconcile current intent, not the selection that started preparation.
        if self.enabled && self.awake && !self.failed && self.settingsError == nil {
          self.applyProcessing()
          self.refresh()
        }
      case .failure(let error):
        if self.settings.noiseReductionMode == .advanced {
          self.failed = true
          self.stopAudio()
          self.status = "Advanced noise reduction: \(error.localizedDescription)"
        }
      }
    }
  }
  func stopAudio() {
    meterTimer?.invalidate(); meterTimer = nil
    readoutTimer?.invalidate(); readoutTimer = nil
    healthTimer?.invalidate(); healthTimer = nil
    #if DEBUG
    profileTimer?.invalidate(); profileTimer = nil
    #endif
    if let engine {
      #if DEBUG
      let stats = ob_engine_diagnostics(engine)
      audioLog.info("Audio stopping: capture=\(stats.captured_frames) dsp=\(stats.signal.output_frames) render=\(stats.render_frames) error=\(stats.error) underruns=\(stats.signal.underruns) overruns=\(stats.signal.overruns)")
      if stats.signal.advanced_deadline_misses > 0 {
        audioLog.error("Advanced NR late output: episodes=\(stats.signal.advanced_deadline_misses) frames=\(stats.signal.advanced_late_frames)")
      }
      if callbackProfiling { logCallbackProfile(ob_engine_stats(engine)) }
      #endif
      ob_engine_destroy(engine)
    }
    engine = nil
    if let audioActivity {
      ProcessInfo.processInfo.endActivity(audioActivity)
      self.audioActivity = nil
    }
    // Preserve the prepared model across mode changes and client reconnects.
    // Attaching it to a new engine resets its signal and recurrent histories.
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
    #if DEBUG
    if callbackProfiling {
      profileTimer = startTimer(10, selector: #selector(recordProfile(_:)))
    }
    #endif
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
    let currentLatency = ob_engine_latency(engine)
    if currentLatency != processingLatency { processingLatency = currentLatency }
    let error = ob_engine_error(engine)
    if error != noErr {
      scheduleRecovery(error == OB_ADVANCED_NR_ERROR ? "Advanced noise reduction" : "Audio processing", error: error)
    }
  }

  #if DEBUG
  @objc private func recordProfile(_ timer: Timer) {
    guard let engine else { return }
    logCallbackProfile(ob_engine_stats(engine))
  }
  #endif

  @objc private func meterTick(_ timer: Timer) { updateMeters() }
  @objc private func readoutTick(_ timer: Timer) { updateReadouts() }

  private func updateMeters() {
    guard let engine else { return }
    meterDisplay.updateLevels(ob_engine_meters(engine))
  }

  private func updateReadouts() {
    guard let engine else { return }
    meterDisplay.updateReadouts(ob_engine_meters(engine))

  }
  #if DEBUG
  private func logCallbackProfile(_ stats: OBEngineStats) {
    let buckets = withUnsafeBytes(of: stats.output_duration_buckets) {
      Array($0.bindMemory(to: UInt64.self))
    }
    let histogram = buckets.map(String.init).joined(separator: ",")
    audioLog.info(
      "Callback profile: inputCount=\(stats.input_callbacks) inputTicks=\(stats.input_total_ticks) inputMaxTicks=\(stats.input_max_ticks) outputCount=\(stats.output_callbacks) outputTicks=\(stats.output_total_ticks) outputMaxTicks=\(stats.callback_max_ticks) outputBudgetExceeded=\(stats.output_budget_exceeded) outputMinFrames=\(stats.output_min_frames) outputMaxFrames=\(stats.output_max_frames) histogram=\(histogram, privacy: .public)")
  }
  #endif
}

struct ContentView: View {
  @ObservedObject var model: AudioModel
  let showSettings: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      MainTitlebar(model: model)
      HStack(spacing: 0) {
        PresetControls(model: model).frame(width: 236)
        Rectangle().fill(UIStyle.line).frame(width: 1)
        VStack(spacing: 0) {
          MainMeterRow(model: model)
          if let error = model.settingsError {
            HStack {
              Text(error).font(.system(size: 12)).foregroundStyle(.orange)
              Spacer()
              Button("Open Settings…", action: showSettings)
            }.padding(.horizontal, 20).padding(.bottom, 10)
          } else if model.presentation.name == "Attention" {
            Text(model.status).font(.system(size: 12)).foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
          }
          if model.availableYetis.count > 1 {
            Picker("Yeti", selection: Binding(get: { model.settings.deviceUID ?? "" }, set: { model.select($0) })) {
              ForEach(model.availableYetis) { Text($0.uid).tag($0.uid) }
            }.padding(.horizontal, 20).padding(.bottom, 10)
          }
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.settings.selectedPreset.name).font(.system(size: 20, weight: .semibold)).lineLimit(1)
            PresetBadge(text: model.presetGroup)
            Spacer()
            Text("\(model.processorCount) of 8 processors on").font(.system(size: 11.5)).foregroundStyle(.tertiary)
          }.padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 10)
          if let notice = model.copyNotice {
            HStack(spacing: 10) {
              Text(notice).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
              Button("OK") { model.copyNotice = nil }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }.padding(.vertical, 9).padding(.horizontal, 12)
              .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
              .padding(.horizontal, 20).padding(.bottom, 10)
          }
          ProcessingEditor(model: model).padding(.horizontal, 20).padding(.bottom, 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(UIStyle.window).ignoresSafeArea()
      .frame(minWidth: 1000, minHeight: 700)
      .background(MeterWindowObserver(model: model))
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  lazy var model = AudioModel()
  private let loginItem = LoginItemModel()
  private let aboutWindow = AboutWindowController()
  let quickAccessWindow = InterfaceWindowReference()
  private lazy var mainWindow = MainWindowController { [self] in
    let host = NSHostingView(rootView: ContentView(model: model, showSettings: { [weak self] in self?.showSettingsWindow() }))
    // The window owns its size and minimum; live readouts must not measure the
    // entire editor to derive new intrinsic, minimum, and maximum sizes.
    host.sizingOptions = []
    return host
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    model.enableAtLaunch()
  }

  private var settingsWindow: NSWindow?
  func showSettingsWindow() {
    quickAccessWindow.window?.orderOut(nil)
    if settingsWindow == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "OpenBlue Settings"
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.contentView = NSHostingView(rootView: OpenBlueSettings(model: model, loginItem: loginItem))
      window.center()
      settingsWindow = window
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showMainWindow() { quickAccessWindow.window?.orderOut(nil); mainWindow.show() }
  func closeMainWindow() { NSApp.keyWindow?.performClose(nil) }
  func showAboutWindow() { quickAccessWindow.window?.orderOut(nil); aboutWindow.show() }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if mainWindow.window?.isVisible == true || mainWindow.window?.isMiniaturized == true {
      showMainWindow()
    }
    return false
  }

  func applicationWillTerminate(_ notification: Notification) { model.stopAudio() }
}

@main struct OpenBlueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  #if DEBUG
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
  #endif
  var body: some Scene {
    MenuBarExtra {
      QuickAccess(model: delegate.model, delegate: delegate)
    } label: {
      MenuBarLabel(model: delegate.model)
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About OpenBlue") { delegate.showAboutWindow() }
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { delegate.showSettingsWindow() }.keyboardShortcut(",", modifiers: .command)
      }
      CommandGroup(replacing: .newItem) {
        Button("Close Window") { delegate.closeMainWindow() }
          .keyboardShortcut("w", modifiers: .command)
      }
    }
  }
}

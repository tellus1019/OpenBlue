import Settings
import SwiftUI

struct PresetControls: View {
  @ObservedObject var model: AudioModel
  @State private var action: NameAction?
  @State private var name = ""
  @State private var confirmingDelete = false

  private enum NameAction: String, Identifiable {
    case create = "New Preset", duplicate = "Duplicate Preset", rename = "Rename Preset"
    var id: String { rawValue }
  }
  private func begin(_ next: NameAction) {
    name = next == .rename ? model.settings.selectedPreset.name : ""
    action = next
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Preset", selection: Binding(
        get: { model.settings.selectedPresetID },
        set: { id in _ = model.changePreset { try $0.selectPreset(id) } }
      )) {
        ForEach(model.settings.presets) { preset in Text(preset.name).tag(preset.id) }
      }
      .disabled(model.settingsError != nil)
      HStack {
        Button("New…") { begin(.create) }
        Button("Duplicate…") { begin(.duplicate) }
        Button("Rename…") { begin(.rename) }
        Button("Delete…", role: .destructive) { confirmingDelete = true }
          .disabled(model.settings.presets.count == 1)
      }.disabled(model.settingsError != nil)
      if model.settingsError == nil {
        Text("Edits are saved automatically to the selected preset.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Back Up…") { model.exportPresets() }.disabled(model.settingsError != nil)
        Button("Restore…") { model.restorePresets() }
        Button("Settings Folder") { model.showSettingsFolder() }
      }
    }
    .confirmationDialog("Delete “\(model.settings.selectedPreset.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete Preset", role: .destructive) {
        _ = model.changePreset { try $0.deleteSelectedPreset() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the preset and switches to the first remaining preset.")
    }
    .sheet(item: $action) { selectedAction in
      VStack(alignment: .leading, spacing: 16) {
        Text(selectedAction.rawValue).font(.headline)
        TextField("Preset name", text: $name)
        if let message = model.presetMessage { Text(message).foregroundStyle(.red) }
        HStack {
          Spacer()
          Button("Cancel") { model.presetMessage = nil; action = nil }.keyboardShortcut(.cancelAction)
          Button("Save") {
            let saved = model.changePreset { settings in
              switch selectedAction {
              case .create: try settings.createPreset(named: name)
              case .duplicate: try settings.createPreset(named: name, duplicatingSelected: true)
              case .rename: try settings.renamePreset(to: name)
              }
            }
            if saved || model.settingsError != nil { model.presetMessage = nil; action = nil }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(24).frame(width: 360)
    }
    .alert("Presets", isPresented: Binding(
      get: { model.presetMessage != nil && action == nil },
      set: { if !$0 { model.presetMessage = nil } }
    )) {
      Button("OK") { model.presetMessage = nil }
    } message: { Text(model.presetMessage ?? "") }
  }
}

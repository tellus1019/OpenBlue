import Settings
import SwiftUI

struct PresetControls: View {
  @ObservedObject var model: AudioModel
  @State private var editingID: UUID?
  @State private var name = ""
  @State private var renameError: String?
  @State private var confirmingDelete = false
  @FocusState private var nameFocused: Bool

  private func beginRename() {
    guard !model.settings.isFactorySelected else { return }
    name = model.settings.selectedPreset.name
    editingID = model.settings.selectedPresetID
    renameError = nil
    nameFocused = true
  }
  private func cancelRename() {
    editingID = nil
    renameError = nil
    nameFocused = false
  }
  private func commitRename() {
    guard let id = editingID else { return }
    guard id == model.settings.selectedPresetID else { cancelRename(); return }
    if model.changePreset({ try $0.renamePreset(to: name) }) { cancelRename() }
    else {
      renameError = model.presetMessage
      model.presetMessage = nil
      nameFocused = true
    }
  }
  private func create(duplicate: Bool) {
    cancelRename()
    let base = duplicate ? model.settings.selectedPreset.name + " Copy" : "New Preset"
    let names = Set(model.settings.presets.map { $0.name.lowercased() })
    var next = base
    var suffix = 2
    while names.contains(next.lowercased()) { next = "\(base) \(suffix)"; suffix += 1 }
    if model.changePreset({ try $0.createPreset(named: next, duplicatingSelected: duplicate) }) { model.copyNotice = nil; beginRename() }
  }
  private func select(_ id: UUID) {
    if editingID != nil { commitRename(); if editingID != nil { return } }
    _ = model.changePreset { try $0.selectPreset(id) }
  }
  private func row(_ preset: Preset, user: Bool) -> some View {
    Group {
      if editingID == preset.id {
        TextField("Preset name", text: $name)
          .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 10)
          .frame(height: 28).background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2))
          .focused($nameFocused).onSubmit(commitRename).onExitCommand(perform: cancelRename)
          .onChange(of: nameFocused) { _, focused in if !focused && editingID != nil { commitRename() } }
      } else {
        Button { select(preset.id) } label: {
          Text(preset.name).font(.system(size: 13)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .foregroundStyle(preset.id == model.settings.selectedPresetID ? Color.white : .primary)
          .background(preset.id == model.settings.selectedPresetID ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
          .simultaneousGesture(TapGesture(count: 2).onEnded {
            if user { select(preset.id); beginRename() }
          })
          .accessibilityAddTraits(preset.id == model.settings.selectedPresetID ? .isSelected : [])
      }
    }.id(preset.id)
  }
  private func heading(_ title: String, top: CGFloat) -> some View {
    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, top).padding(.bottom, 6)
  }
  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 2) {
            heading("My presets", top: 4)
            ForEach(model.settings.userPresets) { row($0, user: true) }
            if let renameError {
              Text(renameError).font(.system(size: 11)).foregroundStyle(.red).padding(8)
            }
            heading("Factory", top: 14)
            ForEach(FactoryPresets.all) { row($0.preset, user: false) }
          }.padding(.horizontal, 10).padding(.vertical, 14)
        }
        .onChange(of: model.settings.selectedPresetID) { _, id in proxy.scrollTo(id) }
        .onChange(of: editingID) { _, id in if let id { proxy.scrollTo(id); nameFocused = true } }
      }
      Rectangle().fill(UIStyle.line).frame(height: 1)
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
        Button("New") { create(duplicate: false) }
        Button("Duplicate") { create(duplicate: true) }
        Button("Rename", action: beginRename).disabled(model.settings.isFactorySelected)
        Button("Delete") { confirmingDelete = true }.disabled(model.settings.isFactorySelected)
      }.buttonStyle(SurfaceButtonStyle()).padding(10)
    }.background(UIStyle.sidebar).disabled(model.settingsError != nil)
      .sheet(isPresented: $confirmingDelete) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Delete “\(model.settings.selectedPreset.name)”?").font(.system(size: 14, weight: .semibold))
          Text("This preset will be removed. Broadcaster 1 will be selected.").font(.system(size: 12)).foregroundStyle(.secondary)
          HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { confirmingDelete = false }.keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) {
              cancelRename()
              _ = model.changePreset { try $0.deleteSelectedPreset() }
              confirmingDelete = false
            }.tint(.red)
          }.padding(.top, 10)
        }.padding(20).frame(width: 340)
      }
      .alert("Presets", isPresented: Binding(get: { model.presetMessage != nil }, set: { if !$0 { model.presetMessage = nil } })) {
        Button("OK") { model.presetMessage = nil }
      } message: { Text(model.presetMessage ?? "") }
  }
}

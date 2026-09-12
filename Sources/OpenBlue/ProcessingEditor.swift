import Settings
import SwiftUI

struct ProcessingEditor: View {
  @ObservedObject var model: AudioModel

  private func value(_ parameter: ProcessingParameter) -> Binding<Float> {
    Binding(
      get: { model.settings.processing[parameter.key] ?? parameter.initial },
      set: { model.settings.processing[parameter.key] = $0; model.save() })
  }

  private func slider(_ p: ProcessingParameter) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(p.label)
        Spacer()
        Text(String(format: p.step < 1 ? "%.1f %@" : "%.0f %@",
                    Double(value(p).wrappedValue), p.unit))
          .monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: value(p), in: p.minimum...p.maximum, step: p.step)
        .accessibilityLabel(p.label)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(ProcessingParameter.stored.filter { $0.group == 0 }) { slider($0) }
      ForEach(1..<9) { group in
        let fields = ProcessingParameter.stored.filter { $0.group == group }
        let enabled = fields[0]
        DisclosureGroup(enabled.label) {
          VStack(spacing: 12) {
            Toggle("Enable " + enabled.label.lowercased(), isOn: Binding(
              get: { value(enabled).wrappedValue == 1 },
              set: { value(enabled).wrappedValue = $0 ? 1 : 0 }))
              .toggleStyle(.switch)
            ForEach(Array(fields.dropFirst())) { slider($0) }
              .disabled(value(enabled).wrappedValue == 0)
            if group == 2 {
              Text("The noise floor uses RMS level; the input meter shows peaks. Start low and increase only as needed. Higher values can affect quiet speech.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.top, 10)
        }
        Divider()
      }
      Text("Processing delay: 12.67 ms (608 frames), including bypass. Device and clock-buffer latency are additional.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .disabled(model.settingsError != nil)
  }
}

import Settings
import SwiftUI

struct ProcessorDescription: Identifiable {
  let id: Int
  let name: String
  let explanation: String
  var parameters: [ProcessingParameter] {
    let fields = ProcessingParameter.stored.filter { $0.group == id }
    if id != 8 { return fields }
    let order = ["limiterEnabled", "limiterBoost", "limiterCeiling", "limiterAttack", "limiterRelease"]
    return order.compactMap { key in fields.first { $0.key == key } }
  }
  var toggle: ProcessingParameter { parameters.first { $0.isToggle }! }
  static let all: [Self] = [
    .init(id: 1, name: "High-pass", explanation: "Removes low-frequency rumble below the cutoff."),
    .init(id: 2, name: "Noise reduction", explanation: "Reduces steady background noise while keeping your voice clear."),
    .init(id: 3, name: "Noise gate", explanation: "Lowers the signal between phrases."),
    .init(id: 4, name: "Equalizer", explanation: "Three peaking bands. Higher Q narrows the affected band."),
    .init(id: 5, name: "De-esser", explanation: "Softens sharp “s” sounds in the selected band."),
    .init(id: 6, name: "De-popper", explanation: "Tames plosive bursts from “p” and “b”."),
    .init(id: 7, name: "Compressor", explanation: "Evens out loud and quiet speech."),
    .init(id: 8, name: "Limiter", explanation: "Keeps peaks under the ceiling with lookahead matching Attack.")
  ]
}

struct ProcessingEditor: View {
  @ObservedObject var model: AudioModel
  private var selected: ProcessorDescription { ProcessorDescription.all.first { $0.id == model.selectedProcessor }! }
  var body: some View {
    VStack(spacing: 10) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
        ForEach(ProcessorDescription.all) { processor in
          HStack(spacing: 8) {
            Toggle(processor.name, isOn: model.processingToggle(processor.toggle.key))
              .labelsHidden().toggleStyle(.switch).controlSize(.mini)
              .frame(width: 26)
            Button { model.selectedProcessor = processor.id } label: {
              Text(processor.name)
                .font(.system(size: 12.5, weight: selected.id == processor.id ? .semibold : .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
              .accessibilityAddTraits(selected.id == processor.id ? .isSelected : [])
          }
          .padding(.horizontal, 10).frame(height: 38)
          .background {
            RoundedRectangle(cornerRadius: 9).fill(selected.id == processor.id ? UIStyle.panel : .clear)
              .contentShape(Rectangle()).onTapGesture { model.selectedProcessor = processor.id }
          }
          .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected.id == processor.id ? .accentColor : UIStyle.line))
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
              Text(selected.name).font(.system(size: 17, weight: .semibold))
              Text(selected.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if selected.id == 2 {
              Picker("Noise reduction method", selection: Binding(
                get: { model.settings.noiseReductionMode },
                set: { mode in
                  // A segmented Picker can call its binding while updating AppKit.
                  // Finish that update before publishing settings or rebuilding audio.
                  Task { @MainActor in
                    _ = model.changePreset { $0.noiseReductionMode = mode }
                  }
                })) {
                Text("Standard").tag(NoiseReductionMode.standard)
                Text("Advanced").tag(NoiseReductionMode.advanced)
              }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
          }
          LazyVGrid(columns: [GridItem(.flexible(), spacing: 40, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 20) {
            if selected.id == 2 && model.settings.noiseReductionMode == .advanced {
              ParameterControl(value: Binding(get: { model.settings.advancedReductionDB }, set: { v in
                _ = model.changePreset { $0.advancedReductionDB = v }
              }), label: "Maximum reduction", band: "", hint: "Lower values keep more of the original signal",
                format: .init(bounds: 0...60, step: 1, unit: "dB"), contextID: model.settings.selectedPresetID)
            } else {
              ForEach(selected.parameters.filter { !$0.isToggle }) { parameter in
                ParameterControl(value: model.processingValue(parameter), label: ParameterCopy.label(parameter),
                  band: ParameterCopy.band(parameter), hint: ParameterCopy.hint(parameter),
                  format: .init(bounds: parameter.minimum...parameter.maximum, step: parameter.step, unit: parameter.unit), contextID: model.settings.selectedPresetID)
              }
            }
          }
        }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UIStyle.line))
      .id(selected.id)
    }
    .opacity(model.settings.bypass ? 0.45 : 1)
    .disabled(model.settingsError != nil)
  }
}

struct ParameterControl: View {
  @Binding var value: Float
  let label: String
  let band: String
  let hint: String
  let format: ParameterValueFormat
  let contextID: UUID
  var body: some View {
    VStack(spacing: 7) {
      HStack(spacing: 8) {
        Text(label).font(.system(size: 12.5, weight: .medium))
        if !band.isEmpty { Text(band).font(.system(size: 11)).foregroundStyle(.tertiary) }
        Spacer(minLength: 0)
        ParameterValueField(value: $value, format: format, label: band.isEmpty ? label : band + " " + label, contextID: contextID)
      }
      ParameterSlider(value: $value, bounds: format.bounds, step: format.step, logarithmic: format.unit == "Hz",
        centered: format.unit == "dB" && format.bounds.lowerBound < 0 && format.bounds.upperBound > 0)
        .frame(height: 18).accessibilityLabel(band.isEmpty ? label : band + " " + label)
      HStack(alignment: .top, spacing: 8) {
        Text(format.text(format.bounds.lowerBound)).fixedSize()
        Text(hint).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        Text(format.text(format.bounds.upperBound)).fixedSize()
      }.font(.system(size: 10.5)).foregroundStyle(.tertiary)
    }
  }
}

private enum ParameterCopy {
  static func band(_ p: ProcessingParameter) -> String {
    guard p.group == 4 else { return "" }
    return p.key.contains("Low") ? "Low" : p.key.contains("Mid") ? "Mid" : "High"
  }
  static func label(_ p: ProcessingParameter) -> String {
    if p.group == 4 { return p.key.hasSuffix("Frequency") ? "Frequency" : p.key.hasSuffix("Gain") ? "Gain" : "Q" }
    if p.key.hasSuffix("Q") { return "Width" }
    if p.key.hasSuffix("Range") { return "Maximum reduction" }
    if p.key.hasSuffix("PreGain") { return "Pre gain" }
    if p.key.hasSuffix("PostGain") { return "Post gain" }
    return p.label
  }
  static func hint(_ p: ProcessingParameter) -> String {
    if p.group == 4 { return p.key.hasSuffix("Frequency") ? "Band center" : p.key.hasSuffix("Gain") ? "Boost or cut" : "Width" }
    if p.group == 5 || p.group == 6 {
      if p.key.hasSuffix("Frequency") { return "Center of the detected band" }
      if p.key.hasSuffix("Q") { return "Higher narrows detection and cut" }
      if p.key.hasSuffix("Threshold") { return "Measured on the filtered band" }
      if p.key.hasSuffix("Range") { return "Caps attenuation at the center" }
    }
    return [
      "hpfFrequency": "−3 dB point of the filter",
      "noiseReductionSensitivity": "More reduction where speech is uncertain",
      "noiseReductionBias": "Treats more of the signal as noise",
      "noiseReductionRange": "Caps attenuation in each band",
      "noiseReductionRelease": "How quickly reduction recovers",
      "gateThreshold": "Level that opens the gate", "gateAttack": "How fast the gate opens",
      "gateHold": "Wait before closing", "gateRelease": "How smoothly the gate closes",
      "gateRange": "Closed level; not necessarily silence",
      "compressorPreGain": "Level into the compressor", "compressorThreshold": "Level where compression starts",
      "compressorRatio": "Slope above the 6 dB soft knee", "compressorPostGain": "Makeup gain after compression",
      "limiterBoost": "Gain before limiting", "limiterCeiling": "Highest sample peak allowed",
      "limiterAttack": "Advance window; 0 is immediate"
    ][p.key] ?? ""
  }
}

import Settings
import SwiftUI

struct ProcessingEditor: View {
  @ObservedObject var model: AudioModel

  private func value(_ parameter: ProcessingParameter) -> Binding<Float> {
    Binding(
      get: { model.settings.processing[parameter.key] ?? parameter.initial },
      set: { value in _ = model.changePreset { $0.processing[parameter.key] = value } })
  }

  private func slider(_ p: ProcessingParameter) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(p.label)
        Spacer()
        Text(String(format: p.step == 0.25 ? "%.2f %@" : p.step < 1 ? "%.1f %@" : "%.0f %@",
                    Double(value(p).wrappedValue), p.unit))
          .monospacedDigit().foregroundStyle(.secondary)
      }
      ParameterSlider(value: value(p), bounds: p.minimum...p.maximum, step: p.step)
        .accessibilityLabel(p.label)
    }
  }

  @ViewBuilder
  private func control(_ p: ProcessingParameter) -> some View {
    if p.isToggle {
      Toggle(p.label, isOn: Binding(get: { value(p).wrappedValue == 1 },
                                  set: { value(p).wrappedValue = $0 ? 1 : 0 }))
    } else { slider(p) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(ProcessingParameter.stored.filter { $0.group == 0 }) { control($0) }
      ForEach(1..<9) { group in
        let fields = ProcessingParameter.stored.filter { $0.group == group }
        let enabled = fields[0]
        DisclosureGroup(enabled.label) {
          VStack(spacing: 12) {
            Toggle("Enable " + enabled.label.lowercased(), isOn: Binding(
              get: { value(enabled).wrappedValue == 1 },
              set: { value(enabled).wrappedValue = $0 ? 1 : 0 }))
              .toggleStyle(.switch)
            if group == 2 {
              Picker("Method", selection: Binding(
                get: { model.settings.noiseReductionMode },
                set: { mode in _ = model.changePreset { $0.noiseReductionMode = mode } })) {
                Text("Standard").tag(NoiseReductionMode.standard)
                Text("Advanced").tag(NoiseReductionMode.advanced)
              }
              if model.settings.noiseReductionMode == .advanced {
                VStack(alignment: .leading, spacing: 3) {
                  HStack {
                    Text("Maximum reduction")
                    Spacer()
                    Text(String(format: "%.0f dB", model.settings.advancedReductionDB)).monospacedDigit()
                  }
                  ParameterSlider(value: Binding(
                    get: { model.settings.advancedReductionDB },
                    set: { value in _ = model.changePreset { $0.advancedReductionDB = value } }),
                    bounds: 0...60, step: 1)
                    .accessibilityLabel("Maximum reduction")
                }.disabled(value(enabled).wrappedValue == 0)
              } else {
                ForEach(Array(fields.dropFirst())) { control($0) }
                  .disabled(value(enabled).wrappedValue == 0)
              }
            } else {
              ForEach(Array(fields.dropFirst())) { control($0) }
                .disabled(value(enabled).wrappedValue == 0)
            }
            if group == 5 || group == 6 {
              let prefix = group == 5 ? "deEsser" : "dePopper"
              let display = model.meterDisplay
              DetectorBandView(
                frequency: Double(model.settings.processing[prefix + "Frequency"] ?? 150),
                q: Double(model.settings.processing[prefix + "Q"] ?? 1))
              HStack {
                Text("Band reduction")
                Spacer()
                MeterReadout(value: group == 5 ? display.deEsserReadout : display.dePopperReadout)
              }.font(.caption)
              ReductionMeterBar(level: group == 5 ? display.deEsser : display.dePopper, band: true)
              Text("Higher Q selects a narrower band. The curve shows detector sensitivity; reduction depends on the signal and threshold.")
                .font(.caption).foregroundStyle(.secondary)
            }
            if group == 2 {
              Text(model.settings.noiseReductionMode == .advanced
                ? "Local speech enhancement. Lower maximum reduction blends back more of the original sound; 0 dB keeps the original. The setting describes suppression of removed sounds, not a guaranteed minimum for every sample. Switching methods restarts processing."
                : "Noise is estimated separately in each frequency band. Start with modest sensitivity and reduction; increase only when needed. Strong suppression can affect quiet speech.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.top, 10)
        }
        .disclosureGroupStyle(ProcessingDisclosureStyle())
        Divider()
      }
      Text(model.processingDelayDescription)
        .font(.caption).foregroundStyle(.secondary)
    }
    .disabled(model.settingsError != nil)
  }
}

private struct DetectorBandView: View {
  let frequency: Double
  let q: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Detection band").font(.caption).foregroundStyle(.secondary)
      Canvas { context, size in
        let center = tan(.pi * frequency / 48_000)
        var curve = Path()
        // Plot the normalized digital band-pass response on a logarithmic axis.
        for index in 0...192 {
          let fraction = Double(index) / 192
          let hz = 20 * pow(1000, fraction)
          let ratio = tan(.pi * hz / 48_000) / center
          let imaginary = ratio / q
          let real = 1 - ratio * ratio
          let gain = imaginary / hypot(real, imaginary)
          let depth = min(36, max(0, -20 * log10(max(gain, 1e-12)))) / 36
          let point = CGPoint(x: fraction * size.width, y: 2 + depth * (size.height - 4))
          if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
      }
      .frame(height: 60)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
      .accessibilityLabel("Detection band centered at \(Int(frequency)) hertz, Q \(q.formatted())")
      HStack {
        Text("20 Hz")
        Spacer()
        Text("20 kHz")
      }.font(.caption2).foregroundStyle(.secondary)
    }
  }
}

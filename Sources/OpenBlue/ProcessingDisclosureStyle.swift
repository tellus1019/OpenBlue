import SwiftUI

struct ProcessingDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    ProcessingDisclosureBody(configuration: configuration)
  }
}

private struct ProcessingDisclosureBody: View {
  let configuration: DisclosureGroupStyleConfiguration
  @State private var hasExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          hasExpanded = true
          configuration.isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
            .accessibilityHidden(true)
          configuration.label
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

      // Keep controls alive after first expansion. Only the enclosing height
      // changes; the content keeps its natural size when collapsed.
      if hasExpanded || configuration.isExpanded {
        configuration.content
          .fixedSize(horizontal: false, vertical: true)
          .frame(height: configuration.isExpanded ? nil : 0, alignment: .top)
          .clipped()
          .opacity(configuration.isExpanded ? 1 : 0)
          .allowsHitTesting(configuration.isExpanded)
          .disabled(!configuration.isExpanded)
          .accessibilityHidden(!configuration.isExpanded)
      }
    }
  }
}

import SwiftUI

/// A claim expires with its verified sample; a completed operation is not proof
/// that the current file generation is still resident on this Mac.
struct AvailabilityBadge: View {
    let value: CatalogAvailability?
    let checkedAt: Date?
    var iconOnly = false
    var body: some View {
        if value != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let current = CatalogAvailability.effective(value, checkedAt: checkedAt, at: context.date) ?? .unknown
                Group {
                    if iconOnly { Image(systemName: current.symbol) }
                    else { Label(current.label, systemImage: current.symbol) }
                }
                .font(.caption)
                .foregroundStyle(current == .attention ? Color.orange : Color.secondary)
                .help(current.label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Offline availability")
                .accessibilityValue(current.label)
            }
        }
    }
}

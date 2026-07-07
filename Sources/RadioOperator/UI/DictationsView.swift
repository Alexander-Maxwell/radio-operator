import SwiftUI
import AppKit

/// Library / Dictations — the day's captured voice notes as a fast, scannable
/// log. (Redesign in progress: full implementation lands with the Dictations
/// screen task.)
struct DictationsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var health: PermissionHealth

    var body: some View {
        VStack {
            Text("Dictations")
                .font(Theme.display(20, .semibold))
                .foregroundStyle(Theme.textMax)
            Text("Redesign in progress")
                .font(Theme.display(12))
                .foregroundStyle(Theme.textMeta)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

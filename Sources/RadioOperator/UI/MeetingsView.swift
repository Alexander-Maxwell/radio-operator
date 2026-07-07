import SwiftUI
import AppKit

/// Library / Meetings — recorded calls as rich knowledge cards, with the
/// structured meeting detail one click away. (Redesign in progress: full
/// implementation lands with the Meetings screens task.)
struct MeetingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var health: PermissionHealth

    var body: some View {
        VStack {
            Text("Meetings")
                .font(Theme.display(20, .semibold))
                .foregroundStyle(Theme.textMax)
            Text("Redesign in progress")
                .font(Theme.display(12))
                .foregroundStyle(Theme.textMeta)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

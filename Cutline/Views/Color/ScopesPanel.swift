import SwiftUI

/// Right panel of the Color tab: video scopes for the frame at the playhead.
struct ScopesPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Scopes")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)
            Spacer()
        }
        .background(Theme.background)
    }
}

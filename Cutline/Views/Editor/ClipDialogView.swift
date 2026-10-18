import SwiftUI

/// Sheet for typing an exact speed or duration for one or more clips.
struct ClipDialogView: View {
    let editor: EditorController
    let dialog: ClipDialog

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var clip: Clip? { editor.state.clip(dialog.clipID) }
    private var count: Int { dialog.clipIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dialog.kind == .speed ? "Clip Speed" : "Clip Duration")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if count > 1 {
                Text("Applies to \(count) clips.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 8) {
                Text(dialog.kind == .speed ? "Speed" : "Duration")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 64, alignment: .leading)
                TextField("", text: $text)
                    .font(.system(size: 13).monospacedDigit())
                    .themedField()
                    .focused($focused)
                    .onSubmit(apply)
                if dialog.kind == .speed {
                    Text("%").foregroundStyle(Theme.textTertiary)
                }
            }

            Text(dialog.kind == .speed
                 ? "10 % to 1000 %. The clip's length follows its new speed, limited by the media and the next clip."
                 : "HH:MM:SS:FF or seconds. Changes the out-point, limited by the media and the next clip.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.destructive)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.background)
        .onAppear {
            guard let clip else { return }
            text = dialog.kind == .speed
                ? String(format: "%g", (clip.speed * 1000).rounded() / 10)
                : Timecode.string(for: clip.duration, fps: editor.fps, alwaysShowHours: true)
            focused = true
        }
    }

    private func apply() {
        switch dialog.kind {
        case .speed:
            guard let percent = Double(text.replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: CharacterSet(charactersIn: " %"))),
                  (10...1000).contains(percent) else {
                error = "Enter a speed between 10 and 1000 %."
                return
            }
            editor.setSpeed(percent / 100, of: dialog.clipIDs)
        case .duration:
            guard let duration = Timecode.parse(text, fps: editor.fps), duration > .zero else {
                error = "Enter a duration like 00:00:05:00 or 5."
                return
            }
            editor.setDuration(duration.snappedToFrame(fps: editor.fps), of: dialog.clipIDs)
        }
        dismiss()
    }
}

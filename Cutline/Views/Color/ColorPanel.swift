import SwiftUI

/// Left panel of the Color tab: the selected clip's grade.
struct ColorPanel: View {
    let editor: EditorController

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel("Color")
                Spacer()
                Toggle(isOn: Binding(get: { editor.bypassGrade }, set: { editor.bypassGrade = $0 })) {
                    Label("Before", systemImage: "circle.lefthalf.filled")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show the ungraded picture (or hold B)")
                if let clip = editor.colorClip {
                    Button("Copy") { editor.copyGrade() }
                        .controlSize(.small)
                        .help("Copy this clip’s grade (⌥⌘C)")
                    Button("Paste") { editor.pasteGrade() }
                        .controlSize(.small)
                        .disabled(editor.copiedGrade == nil)
                        .help(editor.copiedGrade.map { "Paste the grade from “\($0.sourceName)” (⌥⌘V)" } ?? "Copy a grade first")
                    Menu {
                        Button("Apply Grade to All Clips on Track") { editor.applyGradeToTrack(from: clip.id) }
                        Divider()
                        Button("Reset Grade", role: .destructive) { editor.resetGrade(nil, of: clip.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More grade actions")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let clip = editor.colorClip {
                        Group {
                            InspectorSection(title: "Primaries", onReset: { editor.resetGrade(.wheels, of: clip.id) }) {
                                LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(GradeWheel.allCases) { wheel in
                                        ColorWheelControl(editor: editor, clip: clip, wheel: wheel)
                                    }
                                }
                                Text("Drag a wheel to tint (⌥ for fine control) and use its slider for brightness. Double-click a wheel to reset it.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            InspectorSection(title: "Basic", onReset: { editor.resetGrade(.basic, of: clip.id) }) {
                                ForEach(GradeSection.basic.properties) { property in
                                    ParameterRow(editor: editor, clip: clip, property: property)
                                }
                            }
                            RGBCurvesSection(editor: editor, clip: clip)
                            HueSaturationSection(editor: editor, clip: clip)
                            LUTSection(editor: editor, clip: clip)
                        }
                        .disabled(clip.isLocked)
                    } else {
                        InspectorSection(title: "Grade") {
                            Label("Select one video or text clip to grade it.", systemImage: "cursorarrow.click")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background)
    }
}

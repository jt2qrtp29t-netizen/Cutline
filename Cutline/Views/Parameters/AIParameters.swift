import SwiftUI

/// Which local Ollama model Make Thumbnail uses (Parameters → AI).
struct AIParameters: View {
    @Bindable private var settings = AppSettings.shared
    @State private var models: [OllamaClient.Model] = []
    @State private var status: String?
    @State private var isLoading = false

    private var visionModels: [OllamaClient.Model] { models.filter(\.canSeeImages) }

    var body: some View {
        Form {
            Section {
                Picker("Thumbnail model", selection: $settings.thumbnailModel) {
                    Text("Automatic").tag("")
                    ForEach(visionModels) { model in
                        Text(model.size > 0 ? "\(model.name)  (\(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)))" : model.name)
                            .tag(model.name)
                    }
                    // A chosen model that isn't installed now still shows (Automatic is used meanwhile).
                    if !settings.thumbnailModel.isEmpty && !visionModels.contains(where: { $0.name == settings.thumbnailModel }) {
                        Text("\(settings.thumbnailModel) (not installed)").tag(settings.thumbnailModel)
                    }
                }
                HStack {
                    if isLoading { ProgressView().controlSize(.small) }
                    if let status {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Refresh") { Task { await load() } }
                }
            } header: {
                Text("Make Thumbnail")
            } footer: {
                ParameterNote("Make Thumbnail asks a vision model in Ollama, on this Mac, to choose the best frames. Automatic uses the best installed one. A model takes memory only while it's choosing (about its download size, plus a little): Cutline frees it a minute after, or as soon as you close the thumbnail maker. Smaller models load faster and use less memory, e.g. qwen2.5vl:3b (about 3 GB): run “ollama pull qwen2.5vl:3b” in Terminal, then Refresh.")
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await OllamaClient().models()
            status = visionModels.isEmpty
                ? (models.isEmpty ? "Ollama has no models." : "None of Ollama's models can look at images.")
                : "\(visionModels.count) vision model\(visionModels.count == 1 ? "" : "s") in Ollama."
        } catch {
            models = []
            status = "Ollama isn't running. Without it, thumbnails are chosen by picture quality alone."
        }
    }
}

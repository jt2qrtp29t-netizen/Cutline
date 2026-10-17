import SwiftUI

/// Hardware, playback media, generated media and caches.
struct PerformanceParameters: View {
    @Bindable private var settings = AppSettings.shared
    @State private var sizes: [DiskCache: Int64] = [:]
    @State private var confirmClear: DiskCache?
    @State private var estimatesReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Graphics", value: HardwareInfo.gpuName)
                ForEach(HardwareInfo.codecs) { codec in
                    LabeledContent(codec.name) {
                        HStack(spacing: 12) {
                            capability("Decode", HardwareInfo.hasHardwareDecoder(for: codec.type))
                            capability("Encode", HardwareInfo.hardwareEncoders.contains(codec.type))
                        }
                    }
                }
            } header: {
                Text("Hardware")
            } footer: {
                ParameterNote("Video is decoded and encoded by the Mac’s media engine where it can be, and every frame is drawn on the GPU in the decoder’s own format (10-bit when the file is), several at a time. Hardware encoding can be turned off per export for the best HEVC quality per file size, at a much slower speed.")
            }

            Section {
                Picker("Playback uses", selection: $settings.playbackMedia) {
                    ForEach(PlaybackMedia.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Create optimized media when importing", isOn: $settings.createOptimizedOnImport)
                Toggle("Create proxy media when importing", isOn: $settings.createProxyOnImport)
            } header: {
                Text("Playback")
            } footer: {
                ParameterNote("Optimized media are full size ProRes 422 copies, which decode far more easily than H.264 or HEVC. Proxy media are half size ProRes 422 Proxy copies, the lightest to play. You can also make them for a single file by right-clicking it in the media bin. Playback falls back to the original where there’s no copy, and exports always use the original files.")
            }

            Section {
                ForEach(DiskCache.allCases) { cache in
                    LabeledContent(cache.title) {
                        HStack(spacing: 10) {
                            Text(ByteCountFormatter.string(fromByteCount: sizes[cache] ?? 0, countStyle: .file))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                            Button("Clear…") { confirmClear = cache }
                                .disabled((sizes[cache] ?? 0) == 0)
                        }
                    }
                }
            } header: {
                Text("Caches")
            } footer: {
                ParameterNote("Files kept so work isn’t repeated: the sound of movie files, waveforms, and optimized and proxy media. Copies made from an older version of a file are removed automatically, as are audio previews and waveforms unused for two months. Everything here can be remade.")
            }

            Section {
                LabeledContent("Export time estimates") {
                    Button(estimatesReset ? "Reset" : "Reset Learned Speeds") {
                        ExportTimeEstimate.resetLearning()
                        estimatesReset = true
                    }
                    .disabled(estimatesReset)
                }
            } footer: {
                ParameterNote("Estimates start from measured speeds for each encoder and adjust to how long your exports actually take.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await refreshSizes() }
        .confirmationDialog("Clear \(confirmClear?.title.lowercased() ?? "")?", isPresented: Binding(
            get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } }
        ), presenting: confirmClear) { cache in
            Button("Clear", role: .destructive) { clear(cache) }
        } message: { cache in
            Text(cache == .media ? "Playback switches to the original files until new copies are made."
                 : "They’ll be made again when needed.")
        }
    }

    private func capability(_ title: String, _ available: Bool) -> some View {
        Label(title, systemImage: available ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(available ? Theme.accent : Theme.textTertiary)
            .help(available ? "\(title)d in hardware" : "\(title)d in software")
    }

    private func clear(_ cache: DiskCache) {
        switch cache {
        case .media:
            GeneratedMediaLibrary.shared.deleteAll()
        case .audio:
            cache.clear()
            AudioSourceCache.shared.forgetAll()
        case .waveforms, .retimed, .transcripts, .animations:
            cache.clear()
        }
        Task { await refreshSizes() }
    }

    private func refreshSizes() async {
        sizes = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: DiskCache.allCases.map { ($0, $0.size()) })
        }.value
    }
}

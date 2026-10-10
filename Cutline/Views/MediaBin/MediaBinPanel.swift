import SwiftUI

/// Imported media lives here. Accepts Finder drops and is a drag source for the timeline.
struct MediaBinPanel: View {
    let editor: EditorController

    @State private var isDropTargeted = false
    @State private var selectedMedia: UUID?

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 104), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            content
        }
        .background(Theme.background)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .background(Theme.dropTarget, in: .rect(cornerRadius: 8))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            editor.importMedia(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel("Media")
            if !editor.state.media.isEmpty {
                Text("\(editor.state.media.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.raised, in: .capsule)
            }
            Spacer()
            if editor.isImporting {
                ProgressView().controlSize(.small)
            }
            IconButton(systemImage: "plus", help: "Import Media… (⌘I)") {
                editor.showImportPanel()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        if editor.state.media.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("Drop video or audio files here")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("or press ⌘I to import")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(editor.state.media) { media in
                        MediaBinItem(
                            media: media,
                            fps: editor.fps,
                            isSelected: selectedMedia == media.id
                        )
                        .onTapGesture { selectedMedia = media.id }
                        .onDrag {
                            editor.draggedMediaID = media.id
                            let provider = NSItemProvider()
                            provider.register(MediaReference(mediaID: media.id))
                            provider.suggestedName = media.name
                            return provider
                        } preview: {
                            MediaDragPreview(media: media)
                        }
                        .contextMenu { contextMenu(for: media) }
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
        }
    }

    @ViewBuilder
    private func contextMenu(for media: MediaItem) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([MediaURLCache.shared.url(for: media)])
        }
        Divider()
        Button("Remove from Project", role: .destructive) {
            editor.removeMedia([media.id])
        }
    }
}

private struct MediaBinItem: View {
    let media: MediaItem
    let fps: Int
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                PosterThumbnail(media: media)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                Text(Timecode.string(for: media.duration, fps: fps))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.recessed.opacity(0.8), in: .rect(cornerRadius: 3))
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Theme.accent : (isHovering ? Theme.raisedHover : Theme.border),
                                  lineWidth: isSelected ? 2 : 1)
            }
            Text(media.name)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .help(media.hasVideo
              ? "\(media.name)\n\(media.width)×\(media.height) · \(String(format: "%.2f", media.frameRate)) fps\(media.hasAudio ? " · with audio" : "")"
              : "\(media.name)\nAudio")
    }
}

/// Representative frame of a media item, taken a little way in to skip black
/// leaders. Audio-only files show their waveform instead.
struct PosterThumbnail: View {
    let media: MediaItem
    private var cache: ThumbnailCache { .shared }

    var body: some View {
        if media.hasVideo {
            videoPoster
        } else {
            AudioPoster(media: media)
        }
    }

    private var videoPoster: some View {
        let _ = cache.revision
        let time = ThumbnailCache.quantize(media.duration.scaled(by: 0.1), step: Time(seconds: 1))
        let image = cache.image(for: .init(mediaID: media.id, url: MediaURLCache.shared.url(for: media), time: time, size: .poster))
        return ZStack {
            Theme.recessed
            if let image {
                // Scale by the pixel size so the image is never upsampled by SwiftUI.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: image != nil)
    }
}

private struct AudioPoster: View {
    let media: MediaItem
    private var cache: WaveformCache { .shared }

    var body: some View {
        let _ = cache.revision
        let peaks = cache.peaks(for: media, url: MediaURLCache.shared.url(for: media))
        ZStack {
            Theme.audioClipLabelStrip
            if let peaks, !peaks.isEmpty {
                Canvas { context, size in
                    let bars = max(Int(size.width / 2), 1)
                    let mid = size.height / 2
                    var path = Path()
                    for bar in 0..<bars {
                        let i0 = bar * peaks.count / bars
                        let i1 = max(i0 + 1, (bar + 1) * peaks.count / bars)
                        let peak = peaks[i0..<min(i1, peaks.count)].max() ?? 0
                        let h = max(0.5, CGFloat(peak) * mid * 0.8)
                        path.addRect(CGRect(x: CGFloat(bar) * 2, y: mid - h, width: 1.5, height: h * 2))
                    }
                    context.fill(path, with: .color(Theme.waveform))
                }
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.waveform)
            }
        }
    }
}

private struct MediaDragPreview: View {
    let media: MediaItem

    var body: some View {
        PosterThumbnail(media: media)
            .frame(width: 112, height: 63)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.clipBorderSelected, lineWidth: 2))
    }
}

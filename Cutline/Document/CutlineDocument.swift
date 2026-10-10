import SwiftUI
import UniformTypeIdentifiers

/// A `.cutline` project file: JSON describing settings, media references,
/// tracks, clips and markers. Media files are referenced, never copied.
@Observable
final class CutlineDocument: Document {
    nonisolated static let readableContentTypes: [UTType] = [.cutlineProject]

    let store: ProjectStore

    init(state: ProjectState = ProjectState()) {
        store = ProjectStore(state: state)
    }

    nonisolated func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<ProjectState> {
        FileWrapperDocumentReader(configuration) { wrapper in
            guard let data = wrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try ProjectState.decode(data)
        }
    }

    func apply(snapshot: sending ProjectState, previous: sending ProjectState?) async throws {
        store.load(snapshot)
    }

    nonisolated func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<ProjectState> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            FileWrapper(regularFileWithContents: try snapshot.encoded())
        }
    }

    func snapshot(contentType: UTType) async throws -> sending ProjectState {
        store.state
    }
}

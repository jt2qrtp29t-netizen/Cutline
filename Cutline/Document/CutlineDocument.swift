@preconcurrency import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A `.cutline` project file: JSON describing settings, media references,
/// tracks, clips and markers. Media files are referenced, never copied.
/// (Sequoia edition: built on ReferenceFileDocument, which macOS 15 has. SwiftUI may
/// read and save files off the main thread, so the store, which lives on the main
/// actor, is made the first time the editor asks for it.)
nonisolated final class CutlineDocument: ReferenceFileDocument, @unchecked Sendable {
    static let readableContentTypes: [UTType] = [.cutlineProject]
    let objectWillChange = ObservableObjectPublisher()

    private let initialState: ProjectState
    @MainActor private var madeStore: ProjectStore?

    @MainActor var store: ProjectStore {
        if let madeStore { return madeStore }
        let store = ProjectStore(state: initialState)
        madeStore = store
        return store
    }

    init(state: ProjectState = ProjectState()) {
        initialState = state
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        initialState = try ProjectState.decode(data)
    }

    func snapshot(contentType: UTType) throws -> ProjectState {
        if Thread.isMainThread { return MainActor.assumeIsolated { store.state } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { store.state } }
    }

    func fileWrapper(snapshot: ProjectState, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }
}

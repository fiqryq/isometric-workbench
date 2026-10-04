import Combine
import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let isoScene = UTType(exportedAs: "fiqryq.isometric-workbench.scene", conformingTo: .json)
}

/// Latest scene for the save path, which SwiftUI may call off the main actor.
nonisolated final class SceneSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var scene: SceneFile

    init(_ scene: SceneFile) { self.scene = scene }

    var value: SceneFile {
        get { lock.withLock { scene } }
        set { lock.withLock { scene = newValue } }
    }
}

@MainActor
final class SceneDocument: ReferenceFileDocument {
    nonisolated static var readableContentTypes: [UTType] { [.isoScene, .json] }
    nonisolated static var writableContentTypes: [UTType] { [.isoScene, .json] }

    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()
    nonisolated let snapshot: SceneSnapshot
    nonisolated private let initial: SceneFile
    private var cachedModel: SceneModel?

    /// Editor state lives on the main actor; built on first use.
    var model: SceneModel {
        if let cachedModel { return cachedModel }
        let m = SceneModel(scene: initial, snapshot: snapshot)
        cachedModel = m
        return m
    }

    nonisolated init(scene: SceneFile = SceneFile()) {
        initial = scene
        snapshot = SceneSnapshot(scene)
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let scene = try SceneFile.decode(data)
        initial = scene
        snapshot = SceneSnapshot(scene)
    }

    nonisolated func snapshot(contentType: UTType) throws -> SceneFile { snapshot.value }

    nonisolated func fileWrapper(snapshot: SceneFile, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot.encoded())
    }
}

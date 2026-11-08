import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    static let androBridgeRemoteItem = UTType(exportedAs: "io.github.arunmenon1807.androbridge.remote-item")
}

/// A file or folder on the phone being dragged inside AndroBridge.
struct RemoteDragItem: Codable, Transferable {
    let serial: String
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .androBridgeRemoteItem)
    }
}

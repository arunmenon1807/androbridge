import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    static let pixelBridgeRemoteItem = UTType(exportedAs: "app.pixelbridge.remote-item")
}

/// A file or folder on the phone being dragged inside PixelBridge.
struct RemoteDragItem: Codable, Transferable {
    let serial: String
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pixelBridgeRemoteItem)
    }
}

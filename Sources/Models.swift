import AppKit

/// One extracted icon layer, ready for display and export.
struct Layer: Identifiable {
    let id = UUID()
    let name: String
    let groupName: String?
    let pngURL: URL
    let svgURL: URL?
    let image: NSImage
    let width: Int
    let height: Int
}

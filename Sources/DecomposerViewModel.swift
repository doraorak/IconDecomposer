import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DecomposerViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var appName = ""
    @Published var sourceAppIcon: NSImage?
    @Published var layers: [Layer] = []
    @Published var groupCount = 0
    @Published var iconBundleURL: URL?
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var isTargeted = false

    private nonisolated static let composerBundleID = "com.apple.IconComposer"

    // MARK: Decomposing

    func decompose(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        clear()
        sourceURL = url
        appName = url.deletingPathExtension().lastPathComponent
        sourceAppIcon = NSWorkspace.shared.icon(forFile: url.path)
        isProcessing = true

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IconDecomposer_\(UUID().uuidString)")
        Task {
            do {
                let result = try await Task.detached { try Decomposer.run(on: url, outputDir: outDir) }.value
                appName = result.appName
                layers = result.layers
                groupCount = result.groupCount
                iconBundleURL = result.iconBundle
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    func clear() {
        sourceURL = nil
        appName = ""
        sourceAppIcon = nil
        layers = []
        groupCount = 0
        iconBundleURL = nil
        errorMessage = nil
    }

    // MARK: Panels

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application, .applicationBundle, .bundle, .package,
                                     UTType(filenameExtension: "car") ?? .data]
        panel.canChooseDirectories = true
        panel.prompt = "Extract Layers"
        panel.message = "Select an application (.app) or Assets.car"
        if panel.runModal() == .OK, let url = panel.url { decompose(url) }
    }

    func save(_ source: URL, as suggestedName: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Layers"
        panel.message = "Choose a destination folder"
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let folder = parent.appendingPathComponent("\(appName)_icon_layers")
        let files = layers.flatMap { [$0.pngURL, $0.svgURL] }.compactMap { $0 } + [iconBundleURL].compactMap { $0 }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let dest = folder.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: file, to: dest)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func copyToClipboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: Icon Composer

    /// Opens a throwaway copy of the `.icon`, so Icon Composer's autosaves never touch the extraction.
    func openInIconComposer() {
        guard let original = iconBundleURL else { return }
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("IC_Session_\(UUID().uuidString)")
        let copy = sessionDir.appendingPathComponent(original.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: copy)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        guard let composer = Self.iconComposerURL() else {
            NSWorkspace.shared.open(copy)
            return
        }
        NSWorkspace.shared.open([copy], withApplicationAt: composer, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func iconComposerURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: composerBundleID)
            ?? ["/Applications/Xcode.app/Contents/Applications/Icon Composer.app",
                "/Applications/Xcode-beta.app/Contents/Applications/Icon Composer.app",
                "/Applications/Icon Composer.app"]
                .first(where: FileManager.default.fileExists).map { URL(fileURLWithPath: $0) }
    }
}

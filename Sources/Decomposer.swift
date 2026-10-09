import AppKit

/// What a decomposition leaves on disk, ready for the UI.
struct Decomposition {
    let appName: String
    let layers: [Layer]
    let groupCount: Int
    let iconBundle: URL?
}

/// Splits an app's (or Assets.car's) icon into layers and rebuilds it as an `.icon` bundle.
enum Decomposer {
    private typealias Item = [String: Any]
    private static let aqua = "NSAppearanceNameAqua"
    /// The appearances that make up an icon's default rendition (macOS calls it Aqua, iOS-style catalogs Light).
    private static let defaultAppearances = [aqua, "UIAppearanceLight", "default"]
    private static let size = 1024

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func run(on input: URL, outputDir: URL) throws -> Decomposition {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let isBundle = (try? input.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let stem = input.deletingPathExtension().lastPathComponent
        let info = isBundle ? readBundleInfo(input) : (icon: nil, name: stem)

        var layers: [ExtractedLayer] = [], groups: [LayerGroup] = [], baseFill: [String: Any]?
        if let car = findAssetsCar(in: input) {
            (layers, groups, baseFill) = try extractCatalog(car, iconName: info.icon, into: outputDir)
        }
        if layers.isEmpty {
            (layers, groups) = try extractFlatIcon(of: input, into: outputDir)
        }
        guard !layers.isEmpty else { throw Failure(errorDescription: "No icon layers found in \(input.lastPathComponent).") }

        let bundle = outputDir.appendingPathComponent("\(stem).icon")
        let groupCount = try IconBundle.write(to: bundle, layers: layers, groups: groups, baseFill: baseFill)
        return Decomposition(
            appName: info.name,
            layers: layers.compactMap { layer in
                NSImage(contentsOf: layer.png).map {
                    Layer(name: layer.name, groupName: layer.groupName, pngURL: layer.png, svgURL: layer.svg,
                          image: $0, width: layer.width, height: layer.height)
                }
            },
            groupCount: groupCount,
            iconBundle: bundle)
    }

    // MARK: Names and metadata

    /// 'Namespace/02_Foo' -> 'Foo'.
    private static func cleanName(_ raw: String) -> String {
        let name = String(raw.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        let stripped = name.replacingOccurrences(of: #"^\d+[._]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? name : stripped
    }

    /// Generic names like 'Group 3' borrow the name of their first layer.
    private static func groupName(_ raw: String, subs: [Item]) -> String {
        let name = cleanName(raw)
        if name.range(of: #"^group(\s*\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let first = subs.first?["Name"] as? String {
            return cleanName(first).capitalized
        }
        return name.capitalized
    }

    private static func readBundleInfo(_ app: URL) -> (icon: String?, name: String) {
        let fallback = app.deletingPathExtension().lastPathComponent
        for rel in ["Contents/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: app.appendingPathComponent(rel)),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Item else { continue }
            let icon = info["CFBundleIconName"] as? String ?? info["CFBundleIconFile"] as? String
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            return (icon, name ?? fallback)
        }
        return (nil, fallback)
    }

    private static func findAssetsCar(in url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return url.pathExtension == "car" ? url : nil }
        for rel in ["Contents/Resources/Assets.car", "Assets.car", "Contents/Assets.car"] {
            let candidate = url.appendingPathComponent(rel)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let cars = (fm.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "car" }
        return cars.first { $0.lastPathComponent.range(of: "Assets|Theme|Icon", options: .regularExpression) != nil } ?? cars.first
    }

    /// The catalog's contents as listed by `assetutil`.
    private static func readManifest(_ car: URL) -> [Item] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/assetutil")
        process.arguments = ["-I", car.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [Item] ?? []
    }

    // MARK: Catalog extraction

    private static func opacity(_ item: Item) -> Double { IconBundle.number(item, "LayerOpacity", 1) }

    /// The stack named like the bundle icon, preferring its default appearance over dark/tinted variants.
    private static func pickStack(_ stacks: [Item], iconName: String?) -> Item? {
        let named = stacks.filter { $0["Name"] as? String == iconName }
        let candidates = named.isEmpty ? stacks : named
        let isDefault: (Item) -> Bool = { stack in
            (stack["Appearance"] as? String).map(defaultAppearances.contains) ?? true
        }
        return candidates.first(where: isDefault) ?? candidates.first
    }

    /// The stack's layers as groups, bottom to top. A group's layers come from its catalog entry, its glass
    /// settings (specular, shadow, translucency, blur) from the stack's entry for the same appearance.
    private static func collectGroups(_ stack: Item, appearance: String, groupVariants: [String: [String: Item]]) -> [LayerGroup] {
        let stackEntries = (stack["Layers"] as? [Item] ?? []).filter { $0["AssetType"] as? String == "IconGroup" }
        let preferred = [appearance] + defaultAppearances
        func pick(_ variants: [String: Item]) -> Item {
            preferred.lazy.compactMap { variants[$0] }.first ?? variants.sorted { $0.key < $1.key }.first?.value ?? [:]
        }
        var seen = Set<String>()
        return (stack["Layers"] as? [Item] ?? []).compactMap { item in
            guard let name = item["Name"] as? String, seen.insert(name).inserted else { return nil }
            if item["AssetType"] as? String == "IconGroup" {
                let meta = pick(groupVariants[name] ?? [:])
                let settings = pick(Dictionary(stackEntries.filter { $0["Name"] as? String == name }.map {
                    ($0["Appearance"] as? String ?? "default", $0)
                }, uniquingKeysWith: { first, _ in first }))
                let subs = (meta["Layers"] as? [Item] ?? []).filter { $0["Name"] is String && opacity($0) > 0 }
                return subs.isEmpty ? nil : LayerGroup(name: groupName(name, subs: subs), meta: settings, subs: subs)
            }
            guard opacity(item) > 0 else { return nil }
            return LayerGroup(name: cleanName(name).capitalized, meta: item, subs: [item])
        }
    }

    private static func extractCatalog(_ car: URL, iconName: String?, into dir: URL) throws
        -> ([ExtractedLayer], [LayerGroup], [String: Any]?) {
        guard let catalog = CoreUICatalog(url: car) else {
            throw Failure(errorDescription: "CoreUI could not open \(car.path)")
        }
        var colors: [String: Item] = [:], gradients: [String: Item] = [:]
        var groupVariants: [String: [String: Item]] = [:], stacks: [Item] = []
        for item in readManifest(car) {
            guard let kind = item["AssetType"] as? String, let name = item["Name"] as? String else { continue }
            switch kind {
            case "Color": colors[name] = item
            case "Named Gradient": gradients[name] = item
            case "IconGroup": groupVariants[name, default: [:]][item["Appearance"] as? String ?? "default"] = item
            case "IconImageStack", "LayerStack": stacks.append(item)
            default: break
            }
        }

        guard let stack = pickStack(stacks, iconName: iconName) else { return ([], [], nil) }
        let appearance = stack["Appearance"] as? String ?? aqua
        let groups = collectGroups(stack, appearance: appearance, groupVariants: groupVariants)
        var seen = Set<String>()
        let entries = groups.flatMap { g in g.subs.map { (group: g.name, item: $0) } }
            .filter { seen.insert($0.item["Name"] as! String).inserted }

        var layers: [ExtractedLayer] = [], baseFill: [String: Any]?
        for (idx, entry) in entries.enumerated() {
            let item = entry.item, asset = item["Name"] as! String, assetType = item["AssetType"] as? String
            let name = cleanName(asset)
            let slug = name.replacingOccurrences(of: #"[^a-zA-Z0-9_\-]+"#, with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_")).lowercased()
            let stem = String(format: "%02d_%@", idx, slug)
            let png = dir.appendingPathComponent(stem + ".png"), svg = dir.appendingPathComponent(stem + ".svg")
            var kind: ExtractedLayer.Kind?

            if gradients[asset] != nil || assetType == "Named Gradient" || asset.contains("Gradient") {
                let stops = (gradients[asset]?["Gradient Colors"] as? [String] ?? []).map {
                    rgba(colors[$0]?["Color components"] as? [Double] ?? [0.5, 0.5, 0.5, 1])
                }
                if let first = stops.first, let last = stops.last {
                    try writeGradient(from: first, to: last, to: png)
                    kind = .gradient
                    if idx == 0 {
                        baseFill = ["linear-gradient": [displayP3(first), displayP3(last)],
                                    "orientation": ["start": ["x": 0.5, "y": 0.0], "stop": ["x": 0.5, "y": 1.0]]]
                    }
                }
            } else if colors[asset] != nil || assetType == "Color" {
                let color = rgba(colors[asset]?["Color components"] as? [Double] ?? [0.2, 0.5, 0.8, 1])
                try writeColor(color, to: png)
                kind = .color
                if idx == 0 { baseFill = ["solid": displayP3(color)] }
            } else {
                switch catalog.artwork(named: asset, appearance: appearance) {
                case .raster(let cg)?:
                    try writePNG(NSBitmapImageRep(cgImage: cg), to: png)
                    kind = .image
                case .vector(let doc)?:
                    if let data = doc.svgData(), let rep = doc.rasterize(size: size) {
                        try data.write(to: svg)
                        try writePNG(rep, to: png)
                        kind = .vector
                    }
                case nil: break
                }
            }

            guard let kind, let rep = NSBitmapImageRep(data: (try? Data(contentsOf: png)) ?? Data()) else { continue }
            layers.append(ExtractedLayer(
                item: item, name: name, assetName: asset, groupName: entry.group, png: png,
                svg: FileManager.default.fileExists(atPath: svg.path) ? svg : nil,
                kind: kind, width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        return (layers, groups, baseFill)
    }

    /// Fallback for bundles without a layered icon: the rendered icon as one layer.
    private static func extractFlatIcon(of url: URL, into dir: URL) throws -> ([ExtractedLayer], [LayerGroup]) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep.imageReps(with: tiff).compactMap({ $0 as? NSBitmapImageRep })
                  .max(by: { $0.pixelsWide < $1.pixelsWide }) else { return ([], []) }
        let png = dir.appendingPathComponent("00_app_icon.png")
        try writePNG(rep, to: png)
        let layer = ExtractedLayer(item: [:], name: "App Icon", assetName: "AppIcon", groupName: "App Icon", png: png,
                                   svg: nil, kind: .image, width: rep.pixelsWide, height: rep.pixelsHigh)
        return ([layer], [LayerGroup(name: "App Icon", meta: [:], subs: [["Name": "AppIcon"]])])
    }

    // MARK: Pixels

    /// Grayscale, gray+alpha, RGB or RGBA components -> [r, g, b, a].
    private static func rgba(_ components: [Double]) -> [Double] {
        let c = components.isEmpty ? [0.5] : components
        switch c.count {
        case 1: return [c[0], c[0], c[0], 1]
        case 2: return [c[0], c[0], c[0], c[1]]
        default: return [c[0], c[1], c[2], c.count > 3 ? c[3] : 1]
        }
    }

    private static func displayP3(_ c: [Double]) -> String {
        String(format: "display-p3:%.4f,%.4f,%.4f,1.0", c[0], c[1], c[2])
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure(errorDescription: "Could not encode \(url.lastPathComponent).")
        }
        try data.write(to: url)
    }

    /// A square image whose row `y` is `color(y / (size - 1))`.
    private static func writeImage(to url: URL, color: (Double) -> [Double]) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: size * 4, bitsPerPixel: 32)!
        let pixels = rep.bitmapData!
        for y in 0..<size {
            let c = color(Double(y) / Double(size - 1)).map { UInt8(max(0, min(255, $0 * 255))) }
            for x in 0..<size { for k in 0..<4 { pixels[(y * size + x) * 4 + k] = c[k] } }
        }
        try writePNG(rep, to: url)
    }

    private static func writeGradient(from a: [Double], to b: [Double], to url: URL) throws {
        try writeImage(to: url) { t in (0..<3).map { (1 - t) * a[$0] + t * b[$0] } + [1] }
    }

    private static func writeColor(_ c: [Double], to url: URL) throws {
        try writeImage(to: url) { _ in c }
    }
}

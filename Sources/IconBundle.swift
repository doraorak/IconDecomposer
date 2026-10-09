import Foundation

/// A named layer from the catalog together with the files extracted for it.
struct ExtractedLayer {
    let item: [String: Any]   // CoreUI's description of the layer
    let name: String
    let assetName: String
    let groupName: String
    let png: URL
    let svg: URL?
    let kind: Kind
    let width: Int
    let height: Int

    enum Kind { case image, vector, gradient, color }
}

/// A stack entry: an icon group, or a lone layer standing in as its own group.
struct LayerGroup {
    let name: String
    let meta: [String: Any]
    let subs: [[String: Any]]
}

/// Builds an Apple `.icon` bundle that Icon Composer can open.
enum IconBundle {
    private static let blendModes: [String: String] = ["plusl": "plus-lighter", "plusd": "plus-darker"]
    private static let knownBlendModes: Set<String> = [
        "normal", "multiply", "screen", "overlay", "darken", "lighten",
        "soft-light", "hard-light", "plus-lighter", "plus-darker",
    ]

    /// Writes the bundle and returns how many groups it has.
    static func write(to bundle: URL, layers: [ExtractedLayer], groups: [LayerGroup], baseFill: [String: Any]?) throws -> Int {
        let fm = FileManager.default
        let assets = bundle.appendingPathComponent("Assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        for url in layers.flatMap({ [$0.png, $0.svg] }).compactMap({ $0 }) {
            try fm.copyItem(at: url, to: assets.appendingPathComponent(url.lastPathComponent))
        }

        let byAsset = Dictionary(layers.map { ($0.assetName, $0) }, uniquingKeysWith: { first, _ in first })
        func isFlatFill(_ group: LayerGroup) -> Bool {
            group.subs.allSatisfy { sub in
                guard let kind = (sub["Name"] as? String).flatMap({ byAsset[$0]?.kind }) else { return false }
                return kind == .gradient || kind == .color
            }
        }
        // Icon Composer lists layers front to back; CoreUI lists them back to front.
        func layerEntries(_ group: LayerGroup, baseLayer: Bool = false) -> [[String: Any]] {
            group.subs.reversed().compactMap { sub in
                guard let layer = (sub["Name"] as? String).flatMap({ byAsset[$0] }) else { return nil }
                let glass = !baseLayer && ((sub["LayerHasLightingEffects"] as? NSNumber)?.boolValue ?? false)
                return [
                    "blend-mode": blendMode(sub["LayerBlendMode"]),
                    "fill": "automatic",
                    "glass": glass,
                    "image-name": (layer.svg ?? layer.png).lastPathComponent,
                    "name": layer.name,
                    "opacity": number(sub, "LayerOpacity", 1),
                    "position": position(of: sub, imageWidth: layer.width),
                ]
            }
        }

        // The bottom group becomes the icon's "fill" when it is only a gradient or color,
        // otherwise an opaque non-glass base plate when the stack has no fill at all.
        var glassGroups = groups, basePlate: LayerGroup?
        if let bottom = groups.first, !(isFlatFill(bottom) && baseFill != nil) {
            if !isFlatFill(bottom) && baseFill == nil {
                basePlate = bottom
                glassGroups = Array(groups.dropFirst())
            }
        } else {
            glassGroups = Array(groups.dropFirst())
        }

        var entries = glassGroups.reversed().map {
            groupEntry($0.name, layerEntries($0), glass: true, meta: $0.meta)
        }
        if let basePlate { entries.append(groupEntry("Base", layerEntries(basePlate, baseLayer: true), glass: false, meta: [:])) }
        entries = entries.filter { !($0["layers"] as! [Any]).isEmpty }

        let manifest: [String: Any] = [
            "fill": baseFill ?? ["solid": "extended-srgb:0.08,0.55,0.95,1.0"],
            "groups": entries,
            "supported-platforms": ["squares": "shared"],
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: bundle.appendingPathComponent("icon.json"))
        return entries.count
    }

    static func number(_ dict: [String: Any], _ key: String, _ fallback: Double) -> Double {
        ((dict[key] as? NSNumber)?.doubleValue).map { ($0 * 10_000).rounded() / 10_000 } ?? fallback
    }

    /// The layer's frame in the 1024-point canvas (`LayerPosition` is its top-left corner) as scale plus offset from center.
    private static func position(of layer: [String: Any], imageWidth: Int) -> [String: Any] {
        let canvas = 1024.0
        let origin = pair(layer["LayerPosition"]) ?? (0, 0), size = pair(layer["LayerSize"]) ?? (canvas, canvas)
        let scale = imageWidth > 0 ? size.0 / Double(imageWidth) : 1
        return ["scale": scale,
                "translation-in-points": [origin.0 + size.0 / 2 - canvas / 2, origin.1 + size.1 / 2 - canvas / 2]]
    }

    private static func pair(_ raw: Any?) -> (Double, Double)? {
        let parts = (raw as? String)?.split(separator: ",").compactMap { Double($0) }
        return parts?.count == 2 ? (parts![0], parts![1]) : nil
    }

    private static func blendMode(_ raw: Any?) -> String {
        let mode = (raw as? String ?? "normal").trimmingCharacters(in: .whitespaces).lowercased()
        let mapped = blendModes[mode] ?? mode
        return knownBlendModes.contains(mapped) ? mapped : "normal"
    }

    /// A group's glass settings; keys the catalog doesn't carry stay off.
    private static func groupEntry(_ name: String, _ layers: [[String: Any]], glass: Bool, meta: [String: Any]) -> [String: Any] {
        var entry: [String: Any] = ["name": name, "lighting": "individual", "layers": layers]
        guard glass else {
            return entry.merging(["specular": false, "shadow": ["kind": "none", "opacity": 0.0],
                                  "translucency": ["enabled": false, "value": 0.0]]) { $1 }
        }
        entry["specular"] = (meta["LayerHasSpecular"] as? NSNumber)?.boolValue ?? false
        // LayerShadowStyle: 3 = layer-color, 2 = neutral (best effort; absent = no shadow).
        entry["shadow"] = meta["LayerShadowStyle"] == nil
            ? ["kind": "none", "opacity": 0.0]
            : ["kind": (meta["LayerShadowStyle"] as? Int) == 3 ? "layer-color" : "neutral",
               "opacity": min(1, number(meta, "LayerShadowOpacity", 0.5))]
        entry["translucency"] = ["enabled": meta["LayerTranslucency"] != nil, "value": number(meta, "LayerTranslucency", 0)]
        if meta["LayerBlurStrength"] != nil { entry["blur-material"] = number(meta, "LayerBlurStrength", 0) }
        return entry
    }
}

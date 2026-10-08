import SwiftUI

struct ContentView: View {
    @StateObject private var model = DecomposerViewModel()

    var body: some View {
        Group {
            if model.isProcessing {
                ProgressPane(appName: model.appName)
            } else if let error = model.errorMessage {
                ErrorPane(message: error, onRetry: model.chooseApp)
            } else if model.sourceURL == nil {
                DropZone(isTargeted: model.isTargeted, onChoose: model.chooseApp)
            } else {
                ResultsView(model: model)
            }
        }
        .frame(minWidth: 840, minHeight: 580)
        .onDrop(of: [.fileURL], isTargeted: $model.isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.decompose(url) } }
            }
            return true
        }
    }
}

// MARK: - States

private struct ProgressPane: View {
    let appName: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.1)
            Text("Extracting icon layers…").font(.headline)
            if !appName.isEmpty { Text(appName).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorPane: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(.orange)
            Text("Extraction Error").font(.headline)
            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 40)
            Button("Choose Another Application", action: onRetry).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropZone: View {
    let isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [8, 6]))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.015)))
                .padding(36)

            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                VStack(spacing: 6) {
                    Text("Drop Application Here").font(.title3.bold())
                    Text("Split any macOS app icon into its layers")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Application…", action: onChoose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

private struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
    }
}

private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

private struct ResultsView: View {
    @ObservedObject var model: DecomposerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 18)], spacing: 18) {
                    ForEach(model.layers) { LayerCard(layer: $0, model: model) }
                }
                .padding(22)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = model.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            Text(model.appName).font(.headline)
            Badge(text: count(model.layers.count, "layer"))
            if model.groupCount > 0 { Badge(text: count(model.groupCount, "group"), tint: .accentColor) }

            Spacer()

            if model.iconBundleURL != nil {
                Button(action: model.openInIconComposer) {
                    Label("Open in Icon Composer", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.borderedProminent)
            }
            Button(action: model.exportAll) { Label("Export All…", systemImage: "arrow.down.circle") }
            Button(action: model.chooseApp) { Label("Change App", systemImage: "arrow.triangle.2.circlepath") }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct Checkerboard: View {
    private let cell: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) {
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(.primary.opacity((row + col) % 2 == 0 ? 0.06 : 0.02)))
                }
            }
        }
    }
}

private struct LayerCard: View {
    let layer: Layer
    @ObservedObject var model: DecomposerViewModel

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Checkerboard()
                Image(nsImage: layer.image).resizable().aspectRatio(contentMode: .fit).padding(12)
            }
            .frame(height: 145)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .onDrag { NSItemProvider(contentsOf: layer.pngURL) ?? NSItemProvider() }

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(layer.name).font(.subheadline.weight(.semibold)).lineLimit(1).help(layer.name)
                    if let group = layer.groupName, !group.isEmpty {
                        Text(group)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(layer.width) × \(layer.height)").foregroundStyle(.secondary)
                    Text("•").foregroundStyle(.secondary.opacity(0.5))
                    Text(layer.svgURL != nil ? "Vector SVG" : "PNG")
                        .fontWeight(.medium)
                        .foregroundStyle(layer.svgURL != nil ? Color.accentColor : .secondary)
                }
                .font(.caption2)
            }

            HStack(spacing: 8) {
                Button(action: savePNG) { Label("Save PNG", systemImage: "photo") }
                if layer.svgURL != nil { Button(action: saveSVG) { Label("Save SVG", systemImage: "curlybraces") } }
            }
            .font(.caption2.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .contextMenu {
            Button("Save PNG…", action: savePNG)
            if layer.svgURL != nil { Button("Save SVG…", action: saveSVG) }
            Divider()
            Button("Copy Image") { model.copyToClipboard(layer.image) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([layer.pngURL]) }
        }
    }

    private func savePNG() { model.save(layer.pngURL, as: "\(layer.name).png") }

    private func saveSVG() {
        if let svg = layer.svgURL { model.save(svg, as: "\(layer.name).svg") }
    }
}

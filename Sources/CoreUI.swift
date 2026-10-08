import AppKit

/// An asset catalog opened through the private CoreUI framework.
final class CoreUICatalog {
    /// A catalog entry: a raster image, or an SVG document that CoreUI keeps as vectors.
    enum Artwork {
        case raster(CGImage)
        case vector(VectorArtwork)
    }

    /// An SVG document plus the CoreUI objects that own it (it dangles once they are released).
    final class VectorArtwork {
        fileprivate let document: UnsafeRawPointer
        fileprivate let owners: [AnyObject]

        fileprivate init(document: UnsafeRawPointer, owners: [AnyObject]) {
            self.document = document
            self.owners = owners
        }

        func svgData() -> Data? {
            guard let writeSVG = CoreUICatalog.writeSVG else { return nil }
            let data = NSMutableData()
            withExtendedLifetime(owners) { writeSVG(document, data, nil) }
            return data as Data
        }

        func rasterize(size: Int) -> NSBitmapImageRep? {
            guard let drawSVG = CoreUICatalog.drawSVG, let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            withExtendedLifetime(owners) { drawSVG(context.cgContext, document) }
            return rep
        }
    }

    fileprivate typealias DrawSVG = @convention(c) (CGContext, UnsafeRawPointer) -> Void
    fileprivate typealias WriteSVG = @convention(c) (UnsafeRawPointer, CFMutableData, CFDictionary?) -> Void

    private static let coreUI = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)
    fileprivate static let drawSVG: DrawSVG? = symbol("CGContextDrawSVGDocument")
    fileprivate static let writeSVG: WriteSVG? = symbol("CGSVGDocumentWriteToData")

    private let catalog: NSObject

    init?(url: URL) {
        typealias Init = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
        guard Self.coreUI != nil, let cls = NSClassFromString("CUICatalog") as? NSObject.Type else { return nil }
        let object = cls.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        let sel = NSSelectorFromString("initWithURL:error:")
        guard let catalog = Self.send(object, sel, Init.self)(object, sel, url as NSURL, nil)?.takeUnretainedValue() as? NSObject else { return nil }
        self.catalog = catalog
    }

    /// Finds the named asset, trying every lookup CoreUI offers (scales, layout directions, vectors).
    func artwork(named assetName: String, appearance: String) -> Artwork? {
        typealias ByScale = @convention(c) (AnyObject, Selector, NSString, Double) -> Unmanaged<AnyObject>?
        typealias ByLayout = @convention(c) (AnyObject, Selector, NSString, Double, Int, Int) -> Unmanaged<AnyObject>?
        typealias Vector = @convention(c) (AnyObject, Selector, NSString, Double, Int, Int, NSString) -> Unmanaged<AnyObject>?
        typealias Collection = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<NSArray>?

        var lookups: [(NSString) -> Unmanaged<AnyObject>?] = []
        if let (sel, fn) = method("imageWithName:scaleFactor:", ByScale.self) {
            lookups.append { fn(self.catalog, sel, $0, 1) }
        }
        if let (sel, fn) = method("imageWithName:scaleFactor:displayGamut:layoutDirection:", ByLayout.self) {
            lookups += [5, 4, 0, 1, 2, 3].map { dir in { fn(self.catalog, sel, $0, 1, 0, dir) } }
        }
        if let (sel, fn) = method("namedVectorImageWithName:scaleFactor:displayGamut:layoutDirection:appearanceName:", Vector.self) {
            lookups += [5, 4, 0].map { dir in { fn(self.catalog, sel, $0, 1, 0, dir, appearance as NSString) } }
        }
        if let (sel, fn) = method("imagesWithName:", Collection.self) {
            lookups.append { fn(self.catalog, sel, $0)?.takeUnretainedValue().firstObject.map { Unmanaged.passUnretained($0 as AnyObject) } }
        }

        let names = [assetName, assetName.split(separator: "/").last.map(String.init) ?? assetName]
        for lookup in lookups {
            for name in names {
                if let named = lookup(name as NSString)?.takeUnretainedValue() as? NSObject, let art = Self.artwork(of: named) { return art }
            }
        }
        return nil
    }

    // MARK: Runtime plumbing

    private static func artwork(of named: NSObject) -> Artwork? {
        typealias ImageGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
        typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        typealias SVGGetter = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?

        let imageSel = NSSelectorFromString("image")
        if named.responds(to: imageSel), let cg = send(named, imageSel, ImageGetter.self)(named, imageSel)?.takeUnretainedValue() {
            return .raster(cg)
        }
        let renditionSel = NSSelectorFromString("_rendition"), svgSel = NSSelectorFromString("svgDocument")
        guard named.responds(to: renditionSel),
              let rendition = send(named, renditionSel, ObjectGetter.self)(named, renditionSel)?.takeUnretainedValue() as? NSObject,
              rendition.responds(to: svgSel),
              let svg = send(rendition, svgSel, SVGGetter.self)(rendition, svgSel) else { return nil }
        return .vector(VectorArtwork(document: svg, owners: [named, rendition]))
    }

    private func method<T>(_ name: String, _ type: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(name)
        return catalog.responds(to: sel) ? (sel, Self.send(catalog, sel, type)) : nil
    }

    /// The method's implementation as a typed C function (Swift can't message private selectors directly).
    private static func send<T>(_ object: NSObject, _ sel: Selector, _ type: T.Type) -> T {
        unsafeBitCast(object.method(for: sel), to: type)
    }

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(coreUI, name).map { unsafeBitCast($0, to: T.self) }
    }
}

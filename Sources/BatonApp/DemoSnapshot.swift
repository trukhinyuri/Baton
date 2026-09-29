import AppKit
import BatonKit

/// Documentation screenshots without screen capture. With `BATON_DEMO=1` and `BATON_DEMO_SNAPSHOT=<file.png>`, the
/// app draws its main window, title bar included, and the sheet `BATON_DEMO_SHEET` opened on it (with the alert on
/// that sheet, if it shows one), in the light appearance into a PNG at 2x, writes it and quits. AppKit draws the app's own views into a bitmap
/// (`cacheDisplay(in:to:)` on each window's frame view), so no screen-recording permission is involved and nothing
/// else on the screen can end up in the picture. `scripts/screenshots.sh` takes the README's images this way.
@MainActor
enum DemoSnapshot {
    /// The main window's content size in the pictures; demo mode opens at it.
    static let contentSize = NSSize(width: 900, height: 560)
    static let scale: CGFloat = 2
    /// Transparent room around the window for its shadow, in points.
    static let margin: CGFloat = 40
    /// The window's footer under a sheet, in points.
    static let footerRoom: CGFloat = 100

    /// Where to write the picture; `nil` unless demo mode is on and `BATON_DEMO_SNAPSHOT` names a file.
    static func file(_ variables: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard DemoMode.isOn(variables), let path = variables["BATON_DEMO_SNAPSHOT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Called before any window appears: light appearance from the first frame, then the picture once the window
    /// and `sheets` levels of sheets on it (a sheet, then an alert on that sheet) have settled. Gives up after 15
    /// seconds with exit status 1.
    static func take(to file: URL, sheets: Int) {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard let window = mainWindow() else { continue }
                // SwiftUI keeps the window closed at launch when Baton last quit with it closed (the real app shares
                // that state), and a sheet waits until its window is on screen.
                if !window.isVisible { window.orderFrontRegardless() }
                guard window.contentRect(forFrameRect: window.frame).size == contentSize else { continue }
                guard stack(window).count > sheets else { continue }
                do {
                    try await settle(window)
                    try write(window, to: file)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Couldn't write \(file.path): \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            FileHandle.standardError.write(Data("The window didn't appear within 15 seconds; no picture written.\n".utf8))
            exit(1)
        }
    }

    /// Active-window colors (traffic lights, the default button), no text field that could take a keystroke into
    /// the picture, room for a sheet taller than the window, and the end of the sheet's animation.
    private static func settle(_ window: NSWindow) async throws {
        // Activation is cooperative on macOS 14 and later, so a copy started from a shell may stay inactive: ask again
        // until the window (or a sheet on it) is key, and draw nothing with inactive, grey traffic lights.
        let windows = stack(window)
        for _ in 0..<20 {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            windows.last?.makeKey()
            if windows.contains(where: \.isKeyWindow) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard windows.contains(where: \.isKeyWindow) else { throw SnapshotError.notActive }
        for shown in windows { shown.makeFirstResponder(nil) }
        try? await Task.sleep(for: .milliseconds(800))
        // A sheet hangs from the title bar; a tall one gets a taller window, so the footer still shows below it.
        if let sheet = window.attachedSheet, sheet.frame.height + footerRoom > contentSize.height {
            window.setContentSize(NSSize(width: contentSize.width, height: sheet.frame.height + footerRoom))
        }
        try? await Task.sleep(for: .milliseconds(1_000))
        for shown in windows { shown.makeFirstResponder(nil) }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// The window, its sheet and the sheet's own sheet (an alert on it), as far as they go.
    private static func stack(_ window: NSWindow) -> [NSWindow] {
        var windows = [window]
        while let sheet = windows.last?.attachedSheet { windows.append(sheet) }
        return windows
    }

    /// The main window, not the menu bar extra or a sheet.
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
            ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.styleMask.contains(.titled) }
    }

    /// The window and its sheets, each with its shadow, on a transparent canvas large enough for all of them.
    private static func write(_ window: NSWindow, to file: URL) throws {
        guard let windowImage = image(of: window) else { throw SnapshotError.nothingDrawn }
        let windowRect = NSRect(origin: .zero, size: window.frame.size)
        var parts = [(windowImage, windowRect, radius(of: window))]
        for sheet in stack(window).dropFirst() {
            guard let sheetImage = image(of: sheet) else { break }
            let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
            parts.append((sheetImage, NSRect(origin: origin, size: sheet.frame.size), radius(of: sheet)))
        }
        let content = parts.map(\.1).reduce(windowRect) { $0.union($1) }
        let canvas = content.insetBy(dx: -margin, dy: -margin).integral
        guard let output = bitmap(size: canvas.size), let context = NSGraphicsContext(bitmapImageRep: output) else {
            throw SnapshotError.nothingDrawn
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.translateX(by: -canvas.minX, yBy: -canvas.minY)
        transform.concat()
        for (picture, rect, radius) in parts {
            let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            edge.stroke()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = output.representation(using: .png, properties: [:]) else { throw SnapshotError.nothingDrawn }
        try png.write(to: file, options: .atomic)
    }

    /// What the window's frame view draws, title bar included, at 2x whatever the display's scale.
    private static func image(of window: NSWindow) -> NSImage? {
        guard let frameView = window.contentView?.superview, let rep = bitmap(size: frameView.bounds.size) else { return nil }
        frameView.layoutSubtreeIfNeeded()
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func bitmap(size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    /// Windows have rounded corners; a sheet's are rounder.
    private static func radius(of window: NSWindow) -> CGFloat { window.sheetParent == nil ? 10 : 12 }

    enum SnapshotError: LocalizedError {
        case nothingDrawn, notActive
        var errorDescription: String? {
            switch self {
            case .nothingDrawn: "AppKit drew nothing for the window."
            case .notActive: "The window never became the active one, so it would show grey traffic lights."
            }
        }
    }
}

//
//  WallpaperManager.swift
//  Unplug Alarm
//
//  Shows a "protected" / "theft alert" image as desktop wallpaper, which the
//  lock screen (Sonoma+) displays — and swaps live while locked. Saves and
//  restores the user's original wallpaper, including dynamic/aerial ones.
//

import AppKit

/// What to draw on the wallpaper.
struct WallpaperContent {
    enum Style: String {
        case protected
        case alarm
    }

    let style: Style
    let symbolName: String
    let title: String
    /// Secondary lines under the title, top to bottom, with relative font size.
    let lines: [(text: String, size: CGFloat)]
    let rightToLeft: Bool

    static func protected(language: AlarmLanguage, contact: String?, powerTrigger: Bool, lidTrigger: Bool) -> WallpaperContent {
        let subtitleKey: String
        switch (powerTrigger, lidTrigger) {
        case (true, false): subtitleKey = "protected.subtitle.power"
        case (false, true): subtitleKey = "protected.subtitle.lid"
        default: subtitleKey = "protected.subtitle.both"
        }
        var lines: [(String, CGFloat)] = [(language.text(subtitleKey), 0.036)]
        if let contact {
            lines.append((contactLine(contact, language: language), 0.032))
        }
        return WallpaperContent(style: .protected, symbolName: "lock.shield.fill",
                                title: language.text("protected.title"), lines: lines,
                                rightToLeft: language.isRightToLeft)
    }

    static func alarm(language: AlarmLanguage, contact: String?) -> WallpaperContent {
        var lines: [(String, CGFloat)] = []
        if let contact {
            lines.append((contactLine(contact, language: language), 0.042))
        }
        lines.append((language.text("alarm.unlock"), 0.030))
        return WallpaperContent(style: .alarm, symbolName: "exclamationmark.triangle.fill",
                                title: language.text("alarm.title"), lines: lines,
                                rightToLeft: language.isRightToLeft)
    }

    private static func contactLine(_ number: String, language: AlarmLanguage) -> String {
        // Isolate the number as left-to-right so bidi (Arabic) doesn't reorder it.
        String(format: language.text("contact"), "\u{2066}\(number)\u{2069}")
    }
}

final class WallpaperManager {
    /// Legacy UserDefaults keys (state now lives in a file, see `stateURL`).
    private enum LegacyKey {
        static let replaced = "wallpaperReplaced"
        static let backup = "wallpaperBackup"
        static let isStaticImage = "wallpaperIsStaticImage"
    }

    /// Persisted while our image is set as wallpaper. Its existence is the "replaced" flag.
    private struct State: Codable {
        var screens: [String: ScreenBackup]
        var isStaticImage: Bool
    }

    private struct ScreenBackup: Codable {
        var url: String
        var scaling: Int?
        var allowClipping: Bool?
        var fillColor: [CGFloat]?
    }

    private static let staticImageProvider = "com.apple.wallpaper.choice.image"

    /// Used when the original wallpaper is unknown (e.g. state lost in a forced shutdown).
    private static let fallbackWallpaperPaths = [
        "/System/Library/CoreServices/DefaultDesktop.heic",
        "/System/Library/Desktop Pictures/Sonoma.heic",
        "/System/Library/Desktop Pictures/Mac Blue.heic",
    ]

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default

    private var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("UnplugAlarm", isDirectory: true)
    }
    private var imagesDirectory: URL { supportDirectory.appendingPathComponent("Wallpapers", isDirectory: true) }
    private var indexPlistBackupURL: URL { supportDirectory.appendingPathComponent("Index.plist.backup") }
    private var stateURL: URL { supportDirectory.appendingPathComponent("WallpaperState.json") }
    private var systemIndexPlistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// True while our image is set as wallpaper. Persisted (fsync'd to disk, not
    /// UserDefaults) so a crash or forced shutdown can be recovered from.
    var isReplaced: Bool {
        fileManager.fileExists(atPath: stateURL.path) || defaults.bool(forKey: LegacyKey.replaced)
    }

    // MARK: - Public API

    /// Call on launch: restores the original wallpaper if the app died while it was replaced.
    func recoverIfNeeded() {
        if isReplaced {
            print("[Wallpaper] Wallpaper still replaced from a previous run — restoring")
            restore()
        } else if isShowingGeneratedImage() {
            // State was lost (e.g. forced shutdown before it hit the disk) but our
            // image is still the wallpaper. The original is unknown — use the default.
            print("[Wallpaper] Stuck on a generated image without saved state — resetting")
            resetToDefaultWallpaper()
            deleteGeneratedImages()
        } else {
            deleteGeneratedImages()
        }
    }

    /// Manual reset: restores the original wallpaper if known, otherwise falls back
    /// to the macOS default if one of our images is still showing.
    func reset() {
        if isReplaced {
            restore()
        }
        if isShowingGeneratedImage() {
            resetToDefaultWallpaper()
        }
        clearState()
        deleteGeneratedImages()
    }

    /// Sets the given content as wallpaper on every screen. Backs up the
    /// original wallpaper first if it is not already replaced.
    func show(_ content: WallpaperContent) {
        if !isReplaced {
            guard backupOriginal() else {
                print("[Wallpaper] Backup failed — not touching the wallpaper")
                return
            }
        }

        for screen in NSScreen.screens {
            guard let url = render(content, for: screen) else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            } catch {
                print("[Wallpaper] Failed to set wallpaper: \(error)")
            }
        }
    }

    /// Restores the original wallpaper. Static images are restored via the
    /// NSWorkspace API; dynamic/aerial wallpapers by putting back the saved
    /// wallpaper store plist and restarting WallpaperAgent (the API would turn
    /// them into a static image).
    func restore() {
        guard isReplaced else { return }

        if let state = loadState() {
            if !state.isStaticImage, fileManager.fileExists(atPath: indexPlistBackupURL.path) {
                restoreFromPlist(fallback: state)
            } else {
                restoreViaAPI(state)
            }
        } else {
            print("[Wallpaper] No wallpaper backup found — using the default wallpaper")
            resetToDefaultWallpaper()
        }

        clearState()
        deleteGeneratedImages()
    }

    // MARK: - State persistence

    private func loadState() -> State? {
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        // Legacy UserDefaults storage
        if let data = defaults.data(forKey: LegacyKey.backup),
           let screens = try? JSONDecoder().decode([String: ScreenBackup].self, from: data) {
            let isStaticImage = defaults.object(forKey: LegacyKey.isStaticImage) as? Bool ?? true
            return State(screens: screens, isStaticImage: isStaticImage)
        }
        return nil
    }

    private func saveState(_ state: State) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        Self.syncToDisk(stateURL)
    }

    private func clearState() {
        try? fileManager.removeItem(at: stateURL)
        try? fileManager.removeItem(at: indexPlistBackupURL)
        defaults.removeObject(forKey: LegacyKey.replaced)
        defaults.removeObject(forKey: LegacyKey.backup)
        defaults.removeObject(forKey: LegacyKey.isStaticImage)
    }

    /// fsync so the file survives a forced shutdown right after it was written.
    private static func syncToDisk(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        try? handle.synchronize()
        try? handle.close()
    }

    // MARK: - Default wallpaper fallback

    /// True if any screen's wallpaper is one of our generated images.
    func isShowingGeneratedImage() -> Bool {
        NSScreen.screens.contains { screen in
            NSWorkspace.shared.desktopImageURL(for: screen).map(isGeneratedImage) ?? false
        }
    }

    private func isGeneratedImage(_ url: URL) -> Bool {
        let directory = imagesDirectory.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(directory)
    }

    private static var fallbackWallpaperURL: URL? {
        fallbackWallpaperPaths
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func resetToDefaultWallpaper() {
        guard let url = Self.fallbackWallpaperURL else {
            print("[Wallpaper] No default wallpaper found")
            return
        }
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            } catch {
                print("[Wallpaper] Failed to set default wallpaper: \(error)")
            }
        }
    }

    // MARK: - Backup / restore

    private func backupOriginal() -> Bool {
        var backups: [String: ScreenBackup] = [:]
        for screen in NSScreen.screens {
            guard var url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            // Never back up our own image as the "original" (left over from a lost state).
            if isGeneratedImage(url) {
                guard let fallback = Self.fallbackWallpaperURL else { continue }
                url = fallback
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            var fill: [CGFloat]?
            if let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
                fill = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            }
            backups[Self.screenID(screen)] = ScreenBackup(
                url: url.path,
                scaling: (options[.imageScaling] as? NSNumber)?.intValue,
                allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fillColor: fill
            )
        }

        guard !backups.isEmpty else { return false }

        // Also keep a copy of the wallpaper store, needed to restore dynamic wallpapers.
        var isStaticImage = true
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: indexPlistBackupURL)
            try fileManager.copyItem(at: systemIndexPlistURL, to: indexPlistBackupURL)
            Self.syncToDisk(indexPlistBackupURL)
            isStaticImage = Self.usesOnlyStaticImages(plistAt: systemIndexPlistURL)
        } catch {
            print("[Wallpaper] Could not back up wallpaper store: \(error) — falling back to API restore")
        }

        do {
            try saveState(State(screens: backups, isStaticImage: isStaticImage))
        } catch {
            print("[Wallpaper] Could not save wallpaper state: \(error)")
            return false
        }
        return true
    }

    private func restoreViaAPI(_ state: State) {
        let backups = state.screens
        for screen in NSScreen.screens {
            guard let entry = backups[Self.screenID(screen)] ?? backups.values.first else { continue }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = entry.scaling { options[.imageScaling] = scaling }
            if let clipping = entry.allowClipping { options[.allowClipping] = clipping }
            if let fill = entry.fillColor, fill.count == 4 {
                options[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: entry.url), for: screen, options: options)
            } catch {
                print("[Wallpaper] Failed to restore wallpaper: \(error)")
            }
        }
    }

    private func restoreFromPlist(fallback state: State) {
        do {
            let data = try Data(contentsOf: indexPlistBackupURL)
            try data.write(to: systemIndexPlistURL, options: .atomic)
        } catch {
            print("[Wallpaper] Plist restore failed: \(error) — trying API restore")
            restoreViaAPI(state)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[Wallpaper] Failed to restart WallpaperAgent: \(error)")
        }
    }

    /// True if every desktop wallpaper choice in the store uses the static image
    /// provider (as opposed to e.g. `com.apple.wallpaper.choice.sequoia`).
    private static func usesOnlyStaticImages(plistAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        var providers: [String] = []
        collectDesktopProviders(root, insideDesktop: false, into: &providers)
        return !providers.isEmpty && providers.allSatisfy { $0 == staticImageProvider }
    }

    private static func collectDesktopProviders(_ node: Any, insideDesktop: Bool, into providers: inout [String]) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                if insideDesktop, key == "Provider", let provider = value as? String {
                    providers.append(provider)
                } else {
                    collectDesktopProviders(value, insideDesktop: insideDesktop || key == "Desktop", into: &providers)
                }
            }
        } else if let array = node as? [Any] {
            for item in array {
                collectDesktopProviders(item, insideDesktop: insideDesktop, into: &providers)
            }
        }
    }

    private func deleteGeneratedImages() {
        guard let files = try? fileManager.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func screenID(_ screen: NSScreen) -> String {
        "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main")"
    }

    // MARK: - Rendering

    private func render(_ content: WallpaperContent, for screen: NSScreen) -> URL? {
        let width = Int(screen.frame.width * screen.backingScaleFactor)
        let height = Int(screen.frame.height * screen.backingScaleFactor)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawContent(content, size: size)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            // Unique name each time: the same URL may be cached and not refresh.
            let millis = Int(Date().timeIntervalSince1970 * 1000)
            let url = imagesDirectory.appendingPathComponent("\(content.style.rawValue)-\(Self.screenID(screen))-\(millis).png")
            try png.write(to: url)
            return url
        } catch {
            print("[Wallpaper] Failed to write image: \(error)")
            return nil
        }
    }

    private func drawContent(_ content: WallpaperContent, size: NSSize) {
        let bounds = NSRect(origin: .zero, size: size)
        let (top, bottom): (NSColor, NSColor) = content.style == .alarm
            ? (NSColor(srgbRed: 0.80, green: 0.08, blue: 0.10, alpha: 1), NSColor(srgbRed: 0.45, green: 0.03, blue: 0.05, alpha: 1))
            : (NSColor(srgbRed: 0.12, green: 0.24, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.05, green: 0.11, blue: 0.19, alpha: 1))
        NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 90)

        let h = size.height
        let textWidth = size.width * 0.8
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.baseWritingDirection = content.rightToLeft ? .rightToLeft : .leftToRight

        // Build the blocks top to bottom, measure, then center vertically.
        // The lock screen clock sits at the top and the password field at the
        // bottom, so the block stays around the middle.
        enum Block { case symbol(NSImage), text(NSAttributedString, NSSize) }
        var blocks: [(block: Block, height: CGFloat, gapAfter: CGFloat)] = []

        let symbolSize = h * (content.style == .alarm ? 0.11 : 0.10)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        if let template = NSImage(systemSymbolName: content.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            // Tint white while keeping the inner glyph (lock / exclamation mark) cut out.
            let symbol = NSImage(size: template.size, flipped: false) { rect in
                template.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            blocks.append((.symbol(symbol), symbol.size.height, h * 0.03))
        }

        let titleSize = h * (content.style == .alarm ? 0.09 : 0.065)
        let texts: [(String, CGFloat, NSFont.Weight)] =
            [(content.title, titleSize, .heavy)] + content.lines.map { ($0.text, h * $0.size, .semibold) }
        for (index, item) in texts.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: item.1, weight: item.2),
                .foregroundColor: index == 0 ? NSColor.white : NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: paragraph,
            ]
            let string = NSAttributedString(string: item.0, attributes: attributes)
            let measured = string.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            let gap = index == 0 ? item.1 * 0.5 : item.1 * 0.6
            blocks.append((.text(string, measured), ceil(measured.height), gap))
        }

        let totalHeight = blocks.enumerated().reduce(CGFloat(0)) { sum, entry in
            sum + entry.element.height + (entry.offset == blocks.count - 1 ? 0 : entry.element.gapAfter)
        }
        var y = h * 0.5 + totalHeight / 2 // AppKit origin is bottom-left

        for entry in blocks {
            y -= entry.height
            switch entry.block {
            case .symbol(let image):
                let rect = NSRect(x: (size.width - image.size.width) / 2, y: y,
                                  width: image.size.width, height: image.size.height)
                image.draw(in: rect)
            case .text(let string, _):
                let rect = NSRect(x: (size.width - textWidth) / 2, y: y, width: textWidth, height: entry.height)
                string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            y -= entry.gapAfter
        }
    }
}

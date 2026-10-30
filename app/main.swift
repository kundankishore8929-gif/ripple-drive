// Ripple Drive menu-bar app: shows the drive's state, uploads with progress, drop-to-upload on the icon,
// Finder right-click "Upload/Move to Ripple Drive" (macOS Services), reconnect, sign-in and settings.
// It drives the pieces in ~/.local/bin: the mount (LaunchAgent com.ripplemedia.ripple-drive), rclone, and
// ripple-drive-upload (state in ~/.config/ripple-drive/uploads; pause/cancel via marker files there).
// Build: app/build.sh

import AppKit
import Darwin
import Network
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser.path
let mountPath = home + "/RippleDrive"
let stateDir = home + "/.config/ripple-drive/uploads"
let logDir = home + "/Library/Logs/RippleDrive"
let uploadsLog = logDir + "/uploads.log"
let cacheDir = home + "/Library/Caches/RippleDrive"
let rclone = home + "/.local/bin/rclone"
let uploader = home + "/.local/bin/ripple-drive-upload"
let mountAgent = "com.ripplemedia.ripple-drive"
let mountPlist = home + "/Library/LaunchAgents/com.ripplemedia.ripple-drive.plist"
let loginPlist = home + "/Library/LaunchAgents/com.ripplemedia.ripple-drive-app.plist"
let domain = "gui/\(getuid())"

// MARK: - Helpers

@discardableResult
func run(_ path: String, _ args: [String], wait: Bool = true) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = wait ? pipe : FileHandle.nullDevice
    p.standardError = wait ? pipe : FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    guard wait else { return (0, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func human(_ bytes: Double) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .binary      // Google's units (1 TB = 1024^4 bytes), so numbers match drive.google.com
    return f.string(fromByteCount: Int64(bytes))
}

func isMounted() -> Bool {
    var s = statfs()
    guard statfs(mountPath, &s) == 0 else { return false }
    let on = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    return on == mountPath
}

func allocatedSize(_ dir: String) -> Double {
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir),
                                                 includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
    var total = 0.0
    for case let url as URL in e {
        total += Double((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
}

struct Upload {
    let id: String, name: String, dest: String, source: String
    let size: Double, offset: Double
    let error: String?, failed: Bool, paused: Bool
    var fraction: Double { size > 0 ? offset / size : 1 }
}

func readUploads() -> [Upload] {
    let fm = FileManager.default
    let pauseAll = fm.fileExists(atPath: stateDir + "/.pause-all")
    let names = (try? fm.contentsOfDirectory(atPath: stateDir)) ?? []
    var list: [(Double, Upload)] = []
    for n in names where n.hasSuffix(".json") {
        guard let data = fm.contents(atPath: stateDir + "/" + n),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["id"] as? String else { continue }
        let u = Upload(id: id, name: d["name"] as? String ?? n, dest: d["dest"] as? String ?? "",
                       source: d["source"] as? String ?? "",
                       size: (d["size"] as? NSNumber)?.doubleValue ?? 0,
                       offset: (d["offset"] as? NSNumber)?.doubleValue ?? 0,
                       error: d["error"] as? String, failed: d["failed"] as? Bool ?? false,
                       paused: pauseAll || fm.fileExists(atPath: stateDir + "/\(id).pause"))
        list.append(((d["created"] as? NSNumber)?.doubleValue ?? 0, u))
    }
    return list.sorted { $0.0 < $1.0 }.map { $0.1 }
}

/// "uploaded NAME to DEST (SIZE, MD5 matches)" lines from the last 24 hours, newest first.
func finishedToday() -> [String] {
    guard let text = try? String(contentsOfFile: uploadsLog, encoding: .utf8) else { return [] }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let since = Date().addingTimeInterval(-86400)
    var out: [String] = []
    for line in text.split(separator: "\n").suffix(400) {
        guard line.count > 20, let d = fmt.date(from: String(line.prefix(19))), d > since else { continue }
        let msg = line.dropFirst(20)
        if msg.hasPrefix("uploaded "), let r = msg.range(of: " (") {
            let what = msg[msg.index(msg.startIndex, offsetBy: 9)..<r.lowerBound]
            out.append("\(String(line.dropFirst(11).prefix(5)))  \(what)")
        }
    }
    return Array(out.reversed().prefix(15))
}

// MARK: - Ripple mark (menu-bar icon)

/// The Ripple Media mark (256-unit grid, from the brand SVG): a core,
/// then rings of dots (0 core, 1 inner, 2 middle, 3 outer) with an opening at the top. Dot sizes and
/// opacities are raised so the mark still reads at 18 pt in the menu bar.
struct MarkDot { let x: CGFloat, y: CGFloat, a: CGFloat, ring: Int }

let markDots: [MarkDot] = {
    let outer: [(CGFloat, CGFloat, CGFloat)] = [
        (148.5, 11.8, 0.28), (187.0, 25.8, 0.27), (218.4, 52.2, 0.24), (238.9, 87.6, 0.22), (246.0, 128.0, 0.21),
        (238.9, 168.4, 0.20), (218.4, 203.8, 0.19), (187.0, 230.2, 0.19), (148.5, 244.2, 0.20), (107.5, 244.2, 0.22),
        (69.0, 230.2, 0.23), (37.6, 203.8, 0.26), (17.1, 168.4, 0.28), (10.0, 128.0, 0.29), (17.1, 87.6, 0.30),
        (37.6, 52.2, 0.31), (69.0, 25.8, 0.31), (107.5, 11.8, 0.30)]
    let middle: [(CGFloat, CGFloat, CGFloat)] = [
        (148.5, 44.5, 0.57), (185.0, 63.6, 0.53), (208.4, 97.4, 0.48), (213.4, 138.3, 0.44), (198.8, 176.8, 0.42),
        (168.0, 204.1, 0.42), (128.1, 214.0, 0.45), (88.1, 204.2, 0.49), (57.3, 176.9, 0.54), (42.6, 138.4, 0.58),
        (47.6, 97.6, 0.61), (70.9, 63.7, 0.62), (107.4, 44.5, 0.61)]
    let inner: [(CGFloat, CGFloat, CGFloat)] = [
        (128.0, 78.0, 0.98), (163.4, 92.6, 0.92), (178.0, 128.0, 0.86), (163.4, 163.4, 0.84),
        (128.0, 178.0, 0.86), (92.6, 163.4, 0.92), (78.0, 128.0, 0.98), (92.6, 92.6, 1.00)]
    var dots = [MarkDot(x: 128, y: 128, a: 1, ring: 0)]
    dots += inner.map { MarkDot(x: $0.0, y: $0.1, a: $0.2, ring: 1) }
    dots += middle.map { MarkDot(x: $0.0, y: $0.1, a: min(1, $0.2 + 0.25), ring: 2) }
    dots += outer.map { MarkDot(x: $0.0, y: $0.1, a: min(1, $0.2 + 0.35), ring: 3) }
    return dots
}()

let markRadius: [CGFloat] = [1.9, 1.0, 0.72, 0.5]       // points, per ring, at 18 pt

/// How much ring `ring` is swelling at time `t` (0..<1) of one pulse: core first, then each ring outwards,
/// like the brand animation in the Ripple OS launch film.
func markPulse(_ t: CGFloat, ring: Int) -> CGFloat {
    let start = 0.04 + 0.13 * CGFloat(ring), width: CGFloat = 0.22
    let u = (t - start) / width
    return u > 0 && u < 1 ? sin(.pi * u) : 0
}

/// One frame of the mark. `pulse` animates it (nil = still), `reveal` (0...1) pops the rings in on launch,
/// `tint` colours it (nil = a template image that follows the menu bar's light/dark look).
func rippleMark(pulse: CGFloat? = nil, reveal: CGFloat = 1, tint: NSColor? = nil, alpha: CGFloat = 1) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        let s: CGFloat = 18.0 / 256.0
        for d in markDots {
            var scale: CGFloat = 1, op = d.a
            if let t = pulse {
                let k = markPulse(t, ring: d.ring)
                scale += (d.ring <= 1 ? 0.25 : 0.4) * k   // inner dots swell less, or they merge at 18 pt
                op = min(1, op + 0.35 * k)
            }
            if reveal < 1 {                       // each ring grows in after the one inside it
                let local = max(0, min(1, (reveal - 0.18 * CGFloat(d.ring)) / 0.46))
                scale *= 1 - pow(1 - local, 3)
                op *= local
            }
            let r = markRadius[d.ring] * scale
            guard r > 0.01 else { continue }
            (tint ?? .black).withAlphaComponent(op * alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: d.x * s - r, y: d.y * s - r, width: 2 * r, height: 2 * r)).fill()
        }
        return true
    }
    img.isTemplate = tint == nil
    img.accessibilityDescription = "Ripple Drive"
    return img
}

/// One line into ~/Library/Logs/RippleDrive/app.log (drop and click events, for troubleshooting).
func appLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = logDir + "/app.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        h.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

// MARK: - Drop zone that slides out under the icon while a file is dragged near it

/// Menu-bar icons don't receive file drops on macOS 26/27 (the app log showed no drag ever reaching the icon),
/// so a panel appears under the icon whenever something is dragged close to it; a normal panel takes drops.
/// It stays put until the drag ends or the pointer moves well away, so it can't vanish under the file.
final class DropZone: NSObject {
    weak var app: AppDelegate?
    static let size = NSSize(width: 76, height: 62)
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: DropZone.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    let target = ZoneView(frame: NSRect(origin: .zero, size: DropZone.size))
    var monitors: [Any] = []

    func start() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        target.zone = self
        panel.contentView = target
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.dragMoved() } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.dragEnded() } as Any)
    }

    var iconFrame: NSRect? { app?.item.button?.window?.frame }

    /// A drag from Finder (a Finder window or the Desktop) that comes within ~150 pt of the icon shows the zone;
    /// drags in any other app never do. It hides once the pointer is 120 pt clear of the icon and the zone,
    /// or when the drag ends.
    func dragMoved() {
        guard let icon = iconFrame,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let p = NSEvent.mouseLocation
        let near = NSRect(x: icon.midX - 90, y: icon.minY - 110, width: 180, height: icon.height + 120)
        if near.contains(p) {
            if !panel.isVisible { show(under: icon) }
        } else if panel.isVisible && !target.hovering && !near.insetBy(dx: -80, dy: -80).contains(p) {
            panel.orderOut(nil)
        }
    }

    func show(under icon: NSRect) {
        let w = DropZone.size.width
        var x = icon.midX - w / 2
        if let s = NSScreen.screens.first(where: { $0.frame.contains(icon.origin) }) {
            x = min(max(x, s.frame.minX + 4), s.frame.maxX - w - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: icon.minY - DropZone.size.height - 4))
        panel.orderFrontRegardless()
        appLog("drop zone shown")
    }

    /// The drag finished (dropped here or anywhere else): put the zone away once the drop has been handled.
    func dragEnded() {
        guard panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.target.setHover(false)
            self?.panel.orderOut(nil)
        }
    }
}

final class ZoneView: NSView {
    weak var zone: DropZone?
    var hovering = false
    // A small tile right under the icon: the Ripple mark and "Drop here".
    let title = NSTextField(labelWithString: "Drop here")
    let mark = NSImageView(frame: NSRect(x: 23, y: 24, width: 30, height: 30))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.5
        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .popover
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.autoresizingMask = [.width, .height]
        addSubview(fx)
        mark.image = rippleMark()
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.contentTintColor = .labelColor
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 7, width: frame.width, height: 14)
        toolTip = "Drop to upload to Ripple Drive; you choose the folder next"
        [mark, title].forEach { addSubview($0) }
        registerForDraggedTypes([.fileURL])
        setHover(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHover(_ on: Bool) {
        hovering = on
        layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        appLog("drop zone: drag entered")
        setHover(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        appLog("drop zone: drag left")
        setHover(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHover(false)
        zone?.panel.orderOut(nil)
        guard let app = zone?.app else { return false }
        let urls = app.fileURLs(sender.draggingPasteboard)
        appLog("drop zone: dropped \(urls.count) item(s)")
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { app.upload(urls, move: false) }   // always asks where it goes
        return true
    }
}

// MARK: - Drop target over the menu-bar icon

/// A transparent view laid over the status button that takes file drops. Clicks pass straight to the button
/// underneath, so the menu still opens. (Registering the button's window for drags at launch did nothing:
/// that window doesn't exist yet when the app starts.)
final class DropView: NSView {
    weak var app: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { appLog("icon drop target attached, window: \(window != nil)") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        appLog("icon: drag entered")
        guard app?.fileURLs(sender.draggingPasteboard).isEmpty == false else { return [] }
        (superview as? NSButton)?.highlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        app?.fileURLs(sender.draggingPasteboard).isEmpty == false ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { (superview as? NSButton)?.highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? NSButton)?.highlight(false)
        guard let app, case let urls = app.fileURLs(sender.draggingPasteboard), !urls.isEmpty else { return false }
        appLog("icon: dropped \(urls.count) item(s)")
        DispatchQueue.main.async { app.upload(urls, move: false) }
        return true
    }

    override func mouseDown(with e: NSEvent) { appLog("icon: click"); superview?.mouseDown(with: e) }
    override func rightMouseDown(with e: NSEvent) { superview?.rightMouseDown(with: e) }
    override func mouseUp(with e: NSEvent) { superview?.mouseUp(with: e) }
}

/// Target/action wrapper so a control can run a closure.
final class MenuAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

// MARK: - Upload row in the menu

final class UploadRow: NSView {
    let label = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let pause = NSButton()
    let cancel = NSButton()
    var id = ""
    var onPause: ((String) -> Void)?
    var onCancel: ((String) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 44))
        label.font = .menuFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 18, y: 22, width: 250, height: 16)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.frame = NSRect(x: 18, y: 6, width: 250, height: 12)
        for (b, sym, tip) in [(pause, "pause.circle", "Pause"), (cancel, "xmark.circle", "Cancel")] {
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.toolTip = tip
            b.target = self
        }
        pause.frame = NSRect(x: 276, y: 10, width: 22, height: 22)
        cancel.frame = NSRect(x: 302, y: 10, width: 22, height: 22)
        pause.action = #selector(tapPause)
        cancel.action = #selector(tapCancel)
        [label, bar, pause, cancel].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ u: Upload, speed: Double?) {
        id = u.id
        var detail = "\(Int(u.fraction * 100))%"
        if u.failed { detail = "failed" }
        else if u.paused { detail += " · paused" }
        else if let e = u.error { detail += " · waiting: \(e.prefix(40))" }
        else if let s = speed, s > 0 { detail += " · \(human(s))/s" }
        label.stringValue = "\(u.name)  —  \(detail)"
        label.toolTip = "\(u.source)\n→ \(u.dest)\n\(human(u.offset)) of \(human(u.size))" + (u.error.map { "\n\($0)" } ?? "")
        bar.doubleValue = u.fraction
        pause.image = NSImage(systemSymbolName: u.paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
        pause.toolTip = u.paused ? "Resume" : "Pause"
    }

    @objc func tapPause() { onPause?(id) }
    @objc func tapCancel() { onCancel?(id) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let monitor = NWPathMonitor()
    var online = true
    var mounted = true          // until the first check says otherwise, so the launch reveal isn't faded
    var signInExpired = false
    var driveUsed: Double?, driveTotal: Double?
    var cacheBytes = 0.0
    var uploads: [Upload] = []
    var lastOffsets: [String: (Double, Date)] = [:]
    var speeds: [String: Double] = [:]
    var rows: [String: UploadRow] = [:]
    var menuOpen = false
    var lastAboutCheck = Date.distantPast
    var lastCacheCheck = Date.distantPast
    var knownIDs = Set<String>()
    var knownFailed = Set<String>()
    var timer: Timer?
    let defaults = UserDefaults.standard
    lazy var search = SearchController()
    let dropZone = DropZone()

    func applicationDidFinishLaunching(_ n: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: ["notifications": true])
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        if let b = item.button {
            let drop = DropView(frame: b.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.app = self
            b.addSubview(drop)
        }
        dropZone.app = self
        dropZone.start()
        appLog("app started")
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        registerSearchHotKey()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.pathUpdateHandler = { [weak self] p in DispatchQueue.main.async { self?.online = p.status == .satisfied } }
        monitor.start(queue: .global())
        ensureMountAgent()
        revealUntil = Date().addingTimeInterval(1.1)
        updateIcon()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: State

    func refresh() {
        let doAbout = Date().timeIntervalSince(lastAboutCheck) > 900
        let doCache = Date().timeIntervalSince(lastCacheCheck) > 20 || menuOpen
        if doAbout { lastAboutCheck = Date() }
        if doCache { lastCacheCheck = Date() }
        DispatchQueue.global(qos: .utility).async {
            let m = isMounted()
            let ups = readUploads()
            let cache = doCache ? allocatedSize(cacheDir) : nil
            var about: (Double?, Double?, Bool)?
            if doAbout { about = self.checkAbout() }
            DispatchQueue.main.async {
                self.mounted = m
                if let c = cache { self.cacheBytes = c }
                if let a = about { (self.driveUsed, self.driveTotal, self.signInExpired) = a }
                self.update(ups)
            }
        }
    }

    /// `rclone about`: Drive usage, and whether Google still accepts the sign-in.
    func checkAbout() -> (Double?, Double?, Bool) {
        let r = run(rclone, ["about", "rd-my:", "--json"])
        if r.code != 0 {
            let expired = r.out.contains("invalid_grant") || r.out.contains("token expired") || r.out.contains("unauthorized")
            return (driveUsed, driveTotal, expired)
        }
        let start = r.out.firstIndex(of: "{") ?? r.out.startIndex
        let d = (try? JSONSerialization.jsonObject(with: Data(r.out[start...].utf8))) as? [String: Any]
        // Google's "used" is the whole account (Drive + Gmail + Photos): rclone splits it into used + other.
        let used = ((d?["used"] as? NSNumber)?.doubleValue).map { $0 + ((d?["other"] as? NSNumber)?.doubleValue ?? 0) }
        return (used, (d?["total"] as? NSNumber)?.doubleValue, false)
    }

    func update(_ ups: [Upload]) {
        let now = Date()
        for u in ups {
            if let (o, t) = lastOffsets[u.id], u.offset > o {
                let s = (u.offset - o) / now.timeIntervalSince(t)
                speeds[u.id] = speeds[u.id].map { $0 * 0.6 + s * 0.4 } ?? s
                lastOffsets[u.id] = (u.offset, now)
            } else if lastOffsets[u.id] == nil {
                lastOffsets[u.id] = (u.offset, now)
            } else if let (_, t) = lastOffsets[u.id], now.timeIntervalSince(t) > 20 {
                speeds[u.id] = 0
            }
        }
        // Notifications: an id that vanished finished (or was cancelled); a new failure failed.
        let ids = Set(ups.map { $0.id })
        let gone = knownIDs.subtracting(ids)
        if !gone.isEmpty, let first = finishedToday().first, defaults.bool(forKey: "notifications") {
            notify("Uploaded to Ripple Drive", gone.count == 1 ? String(first.dropFirst(7)) : "\(gone.count) files")
        }
        for u in ups where u.failed && !knownFailed.contains(u.id) {
            knownFailed.insert(u.id)
            if defaults.bool(forKey: "notifications") { notify("Upload failed: \(u.name)", u.error ?? "") }
        }
        knownIDs = ids
        let structureChanged = Set(uploads.map { $0.id }) != ids
        uploads = ups
        updateIcon()
        if menuOpen {
            if structureChanged { rebuildMenu() } else { ups.forEach { rows[$0.id]?.show($0, speed: speeds[$0.id]) } }
        }
    }

    var active: [Upload] { uploads.filter { !$0.failed } }

    // The icon is the Ripple mark: still when idle, pulsing ring by ring while uploading, orange when Google
    // is slow, red when the sign-in expired, faded when offline. It pops in once at launch.
    var animTimer: Timer?
    var animStart = Date()
    var revealUntil = Date()
    var iconTint: NSColor?
    var iconAlpha: CGFloat = 1
    var iconPulsing = false

    func updateIcon() {
        guard let b = item.button else { return }
        b.title = ""
        iconTint = nil
        iconAlpha = 1
        let wasPulsing = iconPulsing
        iconPulsing = false
        if signInExpired {
            iconTint = .systemRed
            b.toolTip = "Ripple Drive: Google sign-in expired"
        } else if !online || !mounted {
            iconAlpha = 0.35
            b.toolTip = online ? "Ripple Drive: not connected" : "Ripple Drive: no internet"
        } else if active.contains(where: { $0.error != nil && !$0.paused }) {
            iconTint = .systemOrange
            b.toolTip = "Ripple Drive: Google is slow or limiting; retrying"
        } else if active.contains(where: { !$0.paused }) {
            let size = active.reduce(0) { $0 + $1.size }, done = active.reduce(0) { $0 + $1.offset }
            let pct = Int(100 * done / max(size, 1))
            iconPulsing = true
            b.title = " \(pct)%"
            b.toolTip = "Ripple Drive: uploading \(active.count) file\(active.count == 1 ? "" : "s"), \(pct)%"
        } else {
            b.toolTip = active.isEmpty ? "Ripple Drive" : "Ripple Drive: uploads paused"
        }
        if iconPulsing && !wasPulsing { animStart = Date() }
        if (iconPulsing || Date() < revealUntil) && animTimer == nil {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.drawIcon() }
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        }
        drawIcon()
    }

    func drawIcon() {
        let now = Date()
        let reveal = now < revealUntil ? CGFloat(1 - revealUntil.timeIntervalSince(now) / 1.1) : 1
        let pulse: CGFloat? = iconPulsing
            ? CGFloat(now.timeIntervalSince(animStart).truncatingRemainder(dividingBy: 1.8) / 1.8) : nil
        item.button?.image = rippleMark(pulse: pulse, reveal: reveal, tint: iconTint, alpha: iconAlpha)
        if !iconPulsing && now >= revealUntil {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ m: NSMenu) { rebuildMenu() }
    func menuWillOpen(_ m: NSMenu) { menuOpen = true; refresh() }
    func menuDidClose(_ m: NSMenu) { menuOpen = false }

    func add(_ title: String, _ action: Selector?, key: String = "", to m: NSMenu? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        (m ?? menu).addItem(i)
        return i
    }

    func rebuildMenu() {
        menu.removeAllItems()
        rows.removeAll()
        var status = "On this Mac: \(human(cacheBytes))"
        if let u = driveUsed { status += "  ·  In your Drive: \(human(u))" + (driveTotal.map { " of \(human($0))" } ?? "") }
        add(status, nil).isEnabled = false
        let state: String
        if signInExpired { state = "Google sign-in expired — choose Sign In Again" }
        else if !online { state = "No internet: files open again when you're back online" }
        else if !mounted { state = "Drive not connected — choose Reconnect" }
        else { state = "Connected at ~/RippleDrive" }
        add(state, nil).isEnabled = false
        menu.addItem(.separator())

        if uploads.isEmpty {
            add("No uploads in progress", nil).isEnabled = false
        } else {
            add("Uploads", nil).isEnabled = false
            for u in uploads {
                let row = UploadRow()
                row.onPause = { [weak self] id in self?.togglePause(id) }
                row.onCancel = { [weak self] id in self?.cancelUpload(id) }
                row.show(u, speed: speeds[u.id])
                rows[u.id] = row
                let mi = NSMenuItem()
                mi.view = row
                menu.addItem(mi)
            }
            if uploads.contains(where: { $0.failed }) { _ = add("Retry Failed Uploads", #selector(retryFailed)) }
        }
        let done = finishedToday()
        if !done.isEmpty {
            let sub = NSMenu()
            done.forEach { _ = add($0, nil, to: sub).isEnabled = false }
            add("Uploaded in the Last 24 Hours", nil).submenu = sub
        }
        menu.addItem(.separator())
        _ = add("Open Ripple Drive", #selector(openDrive), key: "o")
        add("Search Drive…", #selector(showSearch), key: "f").keyEquivalentModifierMask = [.control, .option]
        _ = add("Upload Files…", #selector(pickFiles), key: "u")
        let pausedAll = FileManager.default.fileExists(atPath: stateDir + "/.pause-all")
        _ = add(pausedAll ? "Resume All Uploads" : "Pause All Uploads", #selector(togglePauseAll))
        menu.addItem(.separator())
        _ = add("Reconnect Drive", #selector(reconnect))
        _ = add("Sign In Again…", #selector(signIn))
        let settings = NSMenu()
        add("Start at Login", #selector(toggleLogin), to: settings).state =
            FileManager.default.fileExists(atPath: loginPlist) ? .on : .off
        add("Notifications", #selector(toggleNotifications), to: settings).state =
            defaults.bool(forKey: "notifications") ? .on : .off
        add("Settings", nil).submenu = settings
        _ = add("Show Logs", #selector(showLogs))
        menu.addItem(.separator())
        _ = add("Quit Ripple Drive (unmounts the drive)", #selector(quit), key: "q")
    }

    // MARK: Actions

    @objc func openDrive() { NSWorkspace.shared.open(URL(fileURLWithPath: mountPath)) }

    @objc func showSearch() { search.show() }

    @objc func pickFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Choose"
        p.message = "Pick files or folders to upload. They are read where they are, never copied onto the Mac first."
        if p.runModal() == .OK, !p.urls.isEmpty { upload(p.urls, move: false) }
    }

    /// Folders picked before, newest first, that still exist in the drive.
    var recentDests: [String] {
        (defaults.stringArray(forKey: "recentDests") ?? [defaults.string(forKey: "lastDest")].compactMap { $0 })
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Always asks where in the drive the files go: the chooser opens at My Drive, with the last few folders
    /// one click away in "Recent folders". Then hands them to the uploader.
    func upload(_ urls: [URL], move: Bool) {
        let paths = urls.map { $0.path }.filter { !$0.hasPrefix(mountPath + "/") }
        guard !paths.isEmpty else { return alert("These are already in Ripple Drive.") }
        guard mounted else { return alert("Ripple Drive isn't connected. Choose Reconnect Drive, then try again.") }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: mountPath + "/My Drive")
        p.prompt = move ? "Move Here" : "Upload Here"
        let what = paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)”" : "\(paths.count) items"
        p.message = "Choose the Ripple Drive folder for \(what)."

        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 70))
        let label = NSTextField(labelWithString: "Recent folders:")
        label.frame = NSRect(x: 20, y: 40, width: 110, height: 20)
        let recents = NSPopUpButton(frame: NSRect(x: 130, y: 36, width: 410, height: 26), pullsDown: false)
        let list = recentDests
        recents.addItem(withTitle: list.isEmpty ? "None yet" : "Choose a recent folder…")
        list.forEach { recents.addItem(withTitle: String($0.dropFirst(mountPath.count + 1))) }
        recents.isEnabled = !list.isEmpty
        let jump = MenuAction { [weak p, weak recents] in
            guard let r = recents, r.indexOfSelectedItem > 0 else { return }
            p?.directoryURL = URL(fileURLWithPath: list[r.indexOfSelectedItem - 1])
        }
        recents.target = jump
        recents.action = #selector(MenuAction.fire)
        let box = NSButton(checkboxWithTitle: "Move: put the originals in the Trash once Drive confirms each file",
                           target: nil, action: nil)
        box.state = move ? .on : .off
        box.frame = NSRect(x: 18, y: 8, width: 520, height: 20)
        [label, recents, box].forEach { acc.addSubview($0) }
        p.accessoryView = acc
        p.isAccessoryViewDisclosed = true
        let ok = p.runModal() == .OK
        withExtendedLifetime(jump) {}
        guard ok, let dest = p.url?.path else { return }
        guard dest.hasPrefix(mountPath + "/"), dest.split(separator: "/").count > mountPath.split(separator: "/").count else {
            return alert("Pick a folder inside Ripple Drive (My Drive or Shared with me).")
        }
        defaults.set(Array(([dest] + list.filter { $0 != dest }).prefix(6)), forKey: "recentDests")
        startUpload(paths, to: dest, move: box.state == .on)
        notify("Uploading \(paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items")",
               "to \(String(dest.dropFirst(mountPath.count + 1)))")
    }

    func startUpload(_ paths: [String], to dest: String, move: Bool) {
        var args = paths + ["--to", dest]
        if move { args.append("--move") }
        run(uploader, args, wait: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func togglePause(_ id: String) {
        let marker = stateDir + "/\(id).pause"
        if FileManager.default.fileExists(atPath: marker) {
            try? FileManager.default.removeItem(atPath: marker)
            run(uploader, ["--resume"], wait: false)
        } else {
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        refresh()
    }

    @objc func togglePauseAll() {
        let marker = stateDir + "/.pause-all"
        if FileManager.default.fileExists(atPath: marker) {
            try? FileManager.default.removeItem(atPath: marker)
            run(uploader, ["--resume"], wait: false)
        } else {
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        refresh()
    }

    func cancelUpload(_ id: String) {
        guard let u = uploads.first(where: { $0.id == id }) else { return }
        let a = NSAlert()
        a.messageText = "Cancel uploading “\(u.name)”?"
        a.informativeText = "The original stays where it is. What already reached Google is discarded."
        a.addButton(withTitle: "Cancel Upload")
        a.addButton(withTitle: "Keep Uploading")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // A running uploader picks the marker up before its next piece; with none running, clear it here.
        FileManager.default.createFile(atPath: stateDir + "/\(id).cancel", contents: nil)
        if !uploaderRunning() {
            for p in ["\(id).json", "\(id).cancel", "\(id).pause"] { try? FileManager.default.removeItem(atPath: stateDir + "/" + p) }
        }
        refresh()
    }

    func uploaderRunning() -> Bool {
        let fd = open(stateDir + "/.lock", O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    @objc func retryFailed() { run(uploader, ["--resume", "--retry-failed"], wait: false); refresh() }

    func ensureMountAgent() {
        if run("/bin/launchctl", ["print", "\(domain)/\(mountAgent)"]).code != 0 {
            run("/bin/launchctl", ["bootstrap", domain, mountPlist])
        }
    }

    @objc func reconnect() {
        DispatchQueue.global().async {
            if run("/bin/launchctl", ["print", "\(domain)/\(mountAgent)"]).code != 0 {
                run("/bin/launchctl", ["bootstrap", domain, mountPlist])
            } else {
                run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(mountAgent)"])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.refresh() }
        }
    }

    @objc func signIn() {
        notify("Ripple Drive", "Google's sign-in page is opening in your browser.")
        DispatchQueue.global().async {
            let r = run(rclone, ["config", "reconnect", "rd-my:", "--auto-confirm"])
            let ok = r.code == 0
            DispatchQueue.main.async {
                self.lastAboutCheck = .distantPast
                self.notify(ok ? "Signed in to Google again" : "Sign-in didn't finish",
                            ok ? "Ripple Drive is reconnecting." : "Try Sign In Again from the menu.")
                if ok { self.reconnect() } else { self.refresh() }
            }
        }
    }

    @objc func toggleLogin() {
        if FileManager.default.fileExists(atPath: loginPlist) {
            try? FileManager.default.removeItem(atPath: loginPlist)
        } else {
            let plist: [String: Any] = ["Label": "com.ripplemedia.ripple-drive-app",
                                        "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                                        "RunAtLoad": true]
            (plist as NSDictionary).write(toFile: loginPlist, atomically: true)
        }
    }

    @objc func toggleNotifications() { defaults.set(!defaults.bool(forKey: "notifications"), forKey: "notifications") }

    @objc func showLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: logDir)) }

    @objc func quit() {
        run("/bin/launchctl", ["bootout", "\(domain)/\(mountAgent)"])
        NSApp.terminate(nil)
    }

    func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Ripple Drive"
        a.informativeText = text
        a.runModal()
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Drops (DropView over the icon calls upload / quickUpload)

    func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: Finder right-click (macOS Services, declared in Info.plist)

    @objc func uploadService(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(pb)
        DispatchQueue.main.async { self.upload(urls, move: false) }
    }

    @objc func moveService(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(pb)
        DispatchQueue.main.async { self.upload(urls, move: true) }
    }

    @objc func linkService(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = fileURLs(pb).first, url.path.hasPrefix(mountPath + "/") else {
            return notify("Ripple Drive", "Only files inside Ripple Drive have Drive links.")
        }
        makeLink(["link", "--path", url.path]) { [weak self] text in self?.notify("Ripple Drive", text) }
    }
}

// `RippleDrive --render-icon DIR`: writes the menu-bar icon's states as 8x PNGs (for checking the drawing).
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    func save(_ img: NSImage, _ name: String, dark: Bool) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: img.size).fill()
        if dark && img.isTemplate {               // the menu bar draws template icons white in dark mode
            let white = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
            white.draw(in: NSRect(origin: .zero, size: img.size))
        } else {
            img.draw(in: NSRect(origin: .zero, size: img.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    for dark in [false, true] {
        let m = dark ? "dark" : "light"
        save(rippleMark(), "\(m)-1-still", dark: dark)
        for (n, t) in [0.08, 0.2, 0.32, 0.46].enumerated() { save(rippleMark(pulse: CGFloat(t)), "\(m)-2-pulse\(n)", dark: dark) }
        save(rippleMark(tint: .systemOrange), "\(m)-3-slow", dark: dark)
        save(rippleMark(tint: .systemRed), "\(m)-4-signin", dark: dark)
        save(rippleMark(alpha: 0.35), "\(m)-5-offline", dark: dark)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

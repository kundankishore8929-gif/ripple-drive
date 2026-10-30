// ⌃⌥F search panel: type part of a name, Google searches your whole Drive (My Drive + Shared with me), and
// the results open from the mounted drive. Return opens, ⌘Return shows it in Finder, ⌘⇧C copies a share
// link, Esc closes. Searching and links run through ~/.local/bin/ripple-drive-find.

import AppKit
import Carbon
import UniformTypeIdentifiers

let finder = home + "/.local/bin/ripple-drive-find"

struct Hit {
    let id: String, name: String, path: String?, web: String?
    let folder: Bool, size: Double?, modified: Date?
}

func parseJSON(_ text: String) -> Any? {
    guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))
}

/// A Carbon hot key works from any app and needs no Accessibility permission.
var searchHotKey: EventHotKeyRef?

func registerSearchHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.search.show() }
        return noErr
    }, 1, &spec, nil, nil)
    let hotID = EventHotKeyID(signature: OSType(0x5244_5246), id: 1)    // 'RDRF'
    RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey), hotID,
                        GetApplicationEventTarget(), 0, &searchHotKey)
}

final class SearchPanel: NSPanel {
    var onCopyLink: (() -> Void)?
    var onReveal: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .shift], e.charactersIgnoringModifiers?.lowercased() == "c" { onCopyLink?(); return true }
        if mods == [.command], e.keyCode == UInt16(kVK_Return) { onReveal?(); return true }
        return super.performKeyEquivalent(with: e)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class SearchController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
    let field = NSSearchField()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    var hits: [Hit] = []
    var generation = 0
    var debounce: DispatchWorkItem?
    let keys = "⏎ Open     ⌘⏎ Show in Finder     ⌘⇧C Copy link     esc Close"

    override init() {
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.onCopyLink = { [weak self] in self?.copyLink() }
        panel.onReveal = { [weak self] in self?.reveal() }

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        panel.contentView = bg

        field.frame = NSRect(x: 18, y: 362, width: 604, height: 34)
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Search Ripple Drive"
        field.delegate = self
        bg.addSubview(field)

        let col = NSTableColumn(identifier: .init("hit"))
        col.width = 600
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 42
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView(frame: NSRect(x: 6, y: 36, width: 628, height: 318))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        bg.addSubview(scroll)

        status.frame = NSRect(x: 20, y: 10, width: 600, height: 18)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bg.addSubview(status)
    }

    func show() {
        field.stringValue = ""
        hits = []
        table.reloadData()
        status.stringValue = "Type part of a name to search all of your Drive: My Drive and Shared with me."
        if let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - 320, y: f.minY + f.height * 0.64 - 210))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    // MARK: Typing and keys

    func controlTextDidChange(_ n: Notification) {
        debounce?.cancel()
        let words = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard words.count >= 2 else {
            generation += 1
            hits = []
            table.reloadData()
            status.stringValue = words.isEmpty ? "Type part of a name to search all of your Drive." : "Keep typing…"
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.query(words) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil)
        default: return false
        }
        return true
    }

    func move(_ by: Int) {
        guard !hits.isEmpty else { return }
        let row = max(0, min(hits.count - 1, table.selectedRow + by))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func query(_ words: String) {
        generation += 1
        let g = generation
        status.stringValue = "Searching Google Drive…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = run(finder, ["search"] + words.split(separator: " ").map(String.init))
            let parsed = parseJSON(r.out)
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                if let list = parsed as? [[String: Any]] {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    self.hits = list.map {
                        Hit(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                            path: $0["path"] as? String, web: $0["web"] as? String,
                            folder: $0["folder"] as? Bool ?? false, size: ($0["size"] as? NSNumber)?.doubleValue,
                            modified: ($0["modified"] as? String).flatMap { iso.date(from: $0) })
                    }
                    self.table.reloadData()
                    if !self.hits.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
                    self.status.stringValue = self.hits.isEmpty ? "Nothing in your Drive matches “\(words)”." : self.keys
                } else {
                    let err = (parsed as? [String: Any])?["error"] as? String ?? "Google didn't answer"
                    self.status.stringValue = "Search failed: \(err)"
                }
            }
        }
    }

    // MARK: Results

    func numberOfRows(in t: NSTableView) -> Int { hits.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let h = hits[row]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 42))
        let icon = NSImageView(frame: NSRect(x: 4, y: 7, width: 28, height: 28))
        if h.folder {
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            icon.contentTintColor = .systemBlue
        } else {
            let ext = (h.name as NSString).pathExtension
            icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        let name = NSTextField(labelWithString: h.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 40, y: 21, width: 548, height: 17)
        var bits: [String] = []
        if let p = h.path { bits.append((p as NSString).deletingLastPathComponent) } else { bits.append("Opens in the browser") }
        if let s = h.size { bits.append(human(s)) }
        if let m = h.modified {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            bits.append(rel.localizedString(for: m, relativeTo: Date()))
        }
        let sub = NSTextField(labelWithString: bits.joined(separator: "  ·  "))
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingHead
        sub.frame = NSRect(x: 40, y: 4, width: 548, height: 15)
        [icon, name, sub].forEach { v.addSubview($0) }
        return v
    }

    var selected: Hit? {
        let r = table.selectedRow
        return r >= 0 && r < hits.count ? hits[r] : hits.first
    }

    @objc func openSelected() {
        guard let h = selected else { return }
        panel.orderOut(nil)
        if let p = h.path {
            NSWorkspace.shared.open(URL(fileURLWithPath: mountPath + "/" + p))
        } else if let w = h.web, let u = URL(string: w) {
            NSWorkspace.shared.open(u)
        }
    }

    func reveal() {
        guard let h = selected else { return }
        guard let p = h.path else {
            status.stringValue = "“\(h.name)” isn't in the mounted drive (Google Doc or shared drive); ⏎ opens it in the browser."
            return
        }
        panel.orderOut(nil)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPath + "/" + p)])
    }

    func copyLink() {
        guard let h = selected else { return }
        status.stringValue = "Making a share link…"
        makeLink(["link", h.id]) { [weak self] text in self?.status.stringValue = text }
    }
}

/// Runs `ripple-drive-find link …`, copies the link and reports what happened in one line.
func makeLink(_ args: [String], done: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let d = parseJSON(run(finder, args).out) as? [String: Any]
        DispatchQueue.main.async {
            guard let link = d?["link"] as? String else {
                return done("Couldn't make a link: \(d?["error"] as? String ?? "Google didn't answer")")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            let name = d?["name"] as? String ?? "the file"
            done(d?["restricted"] as? Bool == true
                 ? "Link copied. It opens only for people who already have access to “\(name)”."
                 : "Link copied: anyone with it can view “\(name)”.")
        }
    }
}

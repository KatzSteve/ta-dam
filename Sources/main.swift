import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

private let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aiff", "aif", "caf"]

// MARK: - Shared state

struct SoundGroup: Identifiable {
    let name: String
    let sounds: [URL]
    var id: String { name }
}

final class Library: NSObject, ObservableObject, NSSoundDelegate {
    static let shared = Library()

    @Published var groups: [SoundGroup] = []
    @Published var sounds: [URL] = []
    @Published var selected: String? {
        didSet { UserDefaults.standard.set(selected, forKey: "selectedSound") }
    }
    @Published var playOnWake: Bool {
        didSet { UserDefaults.standard.set(playOnWake, forKey: "playOnWake") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var nowPlaying: String?
    @Published var shuffle: Bool {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle") }
    }
    @Published var shuffleCategory: String {
        didSet { UserDefaults.standard.set(shuffleCategory, forKey: "shuffleCategory") }
    }

    private var player: NSSound?
    private var lastPlayedKey: String?

    let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ta-dam/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Stable identity for a sound: its path relative to the library folder
    /// (e.g. "Nature/Ocean waves.mp3"), so same-named files in different
    /// categories never collide.
    func key(_ url: URL) -> String {
        let base = dir.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
    }

    private override init() {
        playOnWake = UserDefaults.standard.object(forKey: "playOnWake") as? Bool ?? true
        shuffle = UserDefaults.standard.bool(forKey: "shuffle")
        shuffleCategory = UserDefaults.standard.string(forKey: "shuffleCategory") ?? "All"
        selected = UserDefaults.standard.string(forKey: "selectedSound")
        super.init()
        refresh()
    }

    /// Subfolders of the sounds directory become categories; loose files in
    /// the root (e.g. from "Add sound…") are grouped under "My sounds".
    func refresh() {
        let fm = FileManager.default
        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        let entries = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted(by: byName)

        var newGroups: [SoundGroup] = []
        var rootSounds: [URL] = []
        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                    .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted(by: byName)
                if !files.isEmpty {
                    newGroups.append(SoundGroup(name: entry.lastPathComponent, sounds: files))
                }
            } else if audioExtensions.contains(entry.pathExtension.lowercased()) {
                rootSounds.append(entry)
            }
        }
        if !rootSounds.isEmpty {
            newGroups.append(SoundGroup(name: "My sounds", sounds: rootSounds))
        }
        // Preferred order; anything else follows alphabetically.
        let priority = ["My sounds", "Nature", "Cars"]
        newGroups.sort { a, b in
            let pa = priority.firstIndex(of: a.name) ?? priority.count
            let pb = priority.firstIndex(of: b.name) ?? priority.count
            if pa != pb { return pa < pb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        groups = newGroups
        sounds = newGroups.flatMap(\.sounds)
        // Migrate a stale selection (old filename-only format, or a file that
        // moved between categories) to the first file with the same name.
        if let current = selected, !sounds.contains(where: { key($0) == current }) {
            let name = (current as NSString).lastPathComponent
            selected = sounds.first { $0.lastPathComponent == name }.map(key)
        }
        if selected == nil {
            selected = sounds.first { $0.lastPathComponent == "Gentle wind.mp3" }.map(key)
                ?? sounds.first.map(key)
        }
    }

    func select(_ url: URL) {
        selected = key(url)
        play(url)
    }

    func playSelected(force: Bool = false) {
        guard force || playOnWake else { return }
        refresh()
        if shuffle {
            var base = sounds
            if shuffleCategory != "All",
               let group = groups.first(where: { $0.name == shuffleCategory }) {
                base = group.sounds
            }
            let pool = base.count > 1
                ? base.filter { key($0) != lastPlayedKey }
                : base
            guard let url = pool.randomElement() else { return }
            play(url)
            return
        }
        guard let url = sounds.first(where: { key($0) == selected }) ?? sounds.first else { return }
        play(url)
    }

    func play(_ url: URL) {
        player?.delegate = nil
        player?.stop()
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.delegate = self
        player = sound
        nowPlaying = key(url)
        lastPlayedKey = key(url)
        sound.play()
    }

    func stop() {
        player?.stop()
        nowPlaying = nil
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, sound === self.player else { return }
            self.nowPlaying = nil
        }
    }

    func addSounds() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for source in panel.urls {
            let dest = dir.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: source, to: dest)
                selected = dest.lastPathComponent
            } catch {
                NSLog("Could not copy sound: \(error.localizedDescription)")
            }
        }
        refresh()
    }

    func moveToTrash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if selected == key(url) { selected = nil }
        refresh()
    }

    // MARK: Multi-delete selection mode

    @Published var deleteMode = false
    @Published var markedForDelete: Set<URL> = []

    func enterDeleteMode(startingWith url: URL) {
        markedForDelete = [url]
        deleteMode = true
    }

    func toggleMarked(_ url: URL) {
        if markedForDelete.contains(url) {
            markedForDelete.remove(url)
        } else {
            markedForDelete.insert(url)
        }
    }

    func deleteMarked() {
        for url in markedForDelete {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if selected == key(url) { selected = nil }
        }
        cancelDeleteMode()
        refresh()
    }

    func cancelDeleteMode() {
        deleteMode = false
        markedForDelete = []
    }

    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch at login change failed: \(error.localizedDescription)")
        }
        launchAtLogin = service.status == .enabled
    }
}

// MARK: - Sound row (shared by popover and window)

struct SoundRow: View {
    @ObservedObject var lib = Library.shared
    let url: URL
    var showsTrash = false
    @State private var hovering = false
    @State private var confirmingDelete = false
    @Environment(\.colorScheme) private var colorScheme

    private var isSelected: Bool { !lib.shuffle && lib.key(url) == lib.selected }
    private var isPlaying: Bool { lib.key(url) == lib.nowPlaying }

    private var checkColor: Color {
        if hovering { return .white }
        if isSelected { return colorScheme == .dark ? .white : .accentColor }
        return Color.secondary.opacity(0.5)
    }

    private var isMarked: Bool { lib.markedForDelete.contains(url) }

    private var markColor: Color {
        if hovering { return .white }
        if isMarked { return colorScheme == .dark ? .white : .accentColor }
        return Color.secondary.opacity(0.5)
    }

    var body: some View {
        HStack(spacing: 8) {
            if lib.deleteMode {
                Image(systemName: isMarked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(markColor)
            } else if !lib.shuffle {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(checkColor)
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
                .foregroundStyle(hovering ? Color.white : Color.primary)
            Spacer()
            if lib.deleteMode {
                EmptyView()
            } else if isPlaying {
                Button {
                    lib.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(hovering ? Color.white : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else if confirmingDelete {
                Button {
                    confirmingDelete = false
                    lib.enterDeleteMode(startingWith: url)
                } label: {
                    Text("Select")
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                }
                .buttonStyle(.borderless)
                Button {
                    confirmingDelete = false
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                }
                .buttonStyle(.borderless)
                Button {
                    confirmingDelete = false
                    lib.moveToTrash(url)
                } label: {
                    Text("Delete")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.2) : Color.white))
                }
                .buttonStyle(.borderless)
            } else if hovering {
                Button {
                    lib.play(url)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.borderless)
                .help("Preview")
                if showsTrash {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 6)
                    .help("Move to Trash")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if lib.deleteMode {
                lib.toggleMarked(url)
            } else if lib.shuffle {
                lib.play(url)
            } else {
                lib.select(url)
            }
        }
        .onHover {
            hovering = $0
            if !$0 { confirmingDelete = false }
        }
    }
}

/// A plain menu-item-style row: hover turns it accent blue, click runs the action.
struct MenuRow: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
            }
            Text(title)
            Spacer(minLength: 0)
        }
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

// MARK: - Menu bar panel

/// Translucent blur backdrop matching system menus.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Borderless floating panel that can become key without activating the app.
final class FloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        contentView = content
    }

    override var canBecomeKey: Bool { true }
}

struct PopoverView: View {
    @ObservedObject var lib = Library.shared
    @State private var query = ""

    private var filteredGroups: [SoundGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return lib.groups }
        return lib.groups.compactMap { group in
            let hits = group.sounds.filter {
                $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(trimmed)
            }
            return hits.isEmpty ? nil : SoundGroup(name: group.name, sounds: hits)
        }
    }

    /// List area height is fixed from the FULL library so the panel doesn't
    /// jump around while filtering.
    private var listHeight: CGFloat {
        min(300, CGFloat(lib.sounds.count) * 27 + CGFloat(lib.groups.count) * 22 + 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("ta-dam")
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            HStack {
                Text("Play sound on wake up")
                Spacer()
                Toggle("Play sound on wake up", isOn: $lib.playOnWake)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 15)
            .padding(.top, 8)
            .padding(.bottom, 4)

            HStack {
                Text("Launch at login")
                Spacer()
                Toggle("Launch at login", isOn: Binding(
                    get: { lib.launchAtLogin },
                    set: { _ in lib.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            .padding(.horizontal, 15)
            .padding(.top, 4)
            .padding(.bottom, 4)

            HStack {
                Text("Shuffle")
                Spacer()
                Toggle("Shuffle", isOn: $lib.shuffle)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 15)
            .padding(.top, 4)
            .padding(.bottom, lib.shuffle ? 4 : 8)

            if lib.shuffle {
                HStack {
                    Text("Shuffle from")
                    Spacer()
                    Menu {
                        Button("All") { lib.shuffleCategory = "All" }
                        ForEach(lib.groups) { group in
                            Button(group.name) { lib.shuffleCategory = group.name }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 5) {
                            Text(lib.shuffleCategory)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 15)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search sounds", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(filteredGroups) { group in
                        Text(group.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 7)
                            .padding(.bottom, 2)
                        ForEach(group.sounds, id: \.self) { url in
                            SoundRow(url: url, showsTrash: true)
                        }
                    }
                    if filteredGroups.isEmpty {
                        Text("No sounds match")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(5)
            }
            .frame(height: listHeight)

            Divider()

            VStack(spacing: 1) {
                if lib.deleteMode {
                    MenuRow(title: lib.markedForDelete.count <= 1
                                ? "Delete \(lib.markedForDelete.count) sound"
                                : "Delete \(lib.markedForDelete.count) sounds",
                            icon: "trash") {
                        lib.deleteMarked()
                    }
                    MenuRow(title: "Cancel", icon: "xmark") {
                        lib.cancelDeleteMode()
                    }
                } else {
                    MenuRow(title: lib.nowPlaying != nil ? "Stop" : "Test sound",
                            icon: lib.nowPlaying != nil ? "stop.fill" : "play") {
                        if lib.nowPlaying != nil {
                            lib.stop()
                        } else {
                            lib.playSelected(force: true)
                        }
                    }
                    MenuRow(title: "Add sound…", icon: "plus") {
                        (NSApp.delegate as? AppDelegate)?.closePanel()
                        lib.addSounds()
                    }
                }
            }
            .padding(5)

            Divider()

            VStack(spacing: 1) {
                MenuRow(title: "Generate sounds on eversince.ai", icon: "waveform") {
                    NSWorkspace.shared.open(URL(string: "https://eversince.ai")!)
                    (NSApp.delegate as? AppDelegate)?.closePanel()
                }
            }
            .padding(5)

            Divider()

            VStack(spacing: 1) {
                MenuRow(title: "Quit ta-dam", icon: "power") {
                    NSApp.terminate(nil)
                }
            }
            .padding(5)
        }
        .frame(width: 300)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            lib.cancelDeleteMode()
            lib.refresh()
        }
        .onChange(of: lib.shuffle) { _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.resizePanel()
            }
        }
    }
}

// MARK: - App delegate (menu bar + wake listener)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel?
    private var hosting: NSHostingView<PopoverView>?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First run: enable launch at login by default (the toggle can turn it
        // off anytime). Done once so a user's later choice is never overridden.
        if !UserDefaults.standard.bool(forKey: "didDefaultLoginItem") {
            UserDefaults.standard.set(true, forKey: "didDefaultLoginItem")
            try? SMAppService.mainApp.register()
            Library.shared.launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ta-dam")
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Library.shared.playSelected()
        }
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let barWindow = button.window else { return }
        Library.shared.refresh()

        // Rebuilt each open so the panel is always sized to its content.
        let hosting = NSHostingView(rootView: PopoverView())
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = FloatingPanel(content: hosting)
        panel.setContentSize(size)
        self.panel = panel
        self.hosting = hosting

        // Float just below the status item, clamped to the screen edge.
        let buttonRect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - size.width / 2
        if let visible = (barWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: buttonRect.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            button.isHighlighted = true
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window != self.panel && event.window != self.statusItem.button?.window {
                self.closePanel()
            }
            return event
        }
    }

    /// Re-fit the panel to its content, keeping the top edge anchored under
    /// the menu bar (panels grow/shrink from the bottom).
    func resizePanel() {
        guard let panel, let hosting else { return }
        let newSize = hosting.fittingSize
        guard newSize.height != panel.frame.height else { return }
        let top = panel.frame.maxY
        let x = panel.frame.minX
        hosting.frame = NSRect(origin: .zero, size: newSize)
        panel.setContentSize(newSize)
        panel.setFrameOrigin(NSPoint(x: x, y: top - newSize.height))
    }

    func closePanel() {
        statusItem.button?.isHighlighted = false
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

}

// Single-instance guard: if another ta-dam is already running (e.g. a second
// copy of the bundle at a different path), quietly exit instead of doubling up.
let myPid = ProcessInfo.processInfo.processIdentifier
let bundleId = Bundle.main.bundleIdentifier ?? "app.tadam.menubar"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .contains(where: { $0.processIdentifier != myPid }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

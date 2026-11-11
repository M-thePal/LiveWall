import AppKit
import AVFoundation
import IOKit.ps
import ServiceManagement

// One borderless window per screen, sitting at desktop level, looping a muted video.
final class Wall {
    let window: NSWindow
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?

    init(screen: NSScreen, url: URL) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView(frame: screen.frame)
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        window.orderFrontRegardless()
    }

    func close() { player.pause(); looper?.disableLooping(); window.close() }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let videosDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/LiveWall")
    var walls: [Wall] = []
    var url: URL?
    let debug = ProcessInfo.processInfo.environment["LIVEWALL_DEBUG"] != nil
    var userPaused = false
    var screensAsleep = false
    var pauseOnBattery: Bool {
        get { defaults.object(forKey: "pauseOnBattery") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pauseOnBattery") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        item.button?.title = "🎞"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu

        if let p = defaults.string(forKey: "video"), FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
        else { url = videos().first?.url }
        rebuild()
        // a system update can rewrite the manifest and silently drop our lock screen entry
        if let p = defaults.string(forKey: "lockVideo"), let id = defaults.string(forKey: "lockID"),
           !LockScreen.isInstalled(id), FileManager.default.fileExists(atPath: p) { setLock(URL(fileURLWithPath: p)) }

        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(rebuild), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [self] _ in screensAsleep = true; refresh() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [self] _ in screensAsleep = false; refresh() }
        }
        // shortcut: polling power state every 10s, switch to IOPSNotificationCreateRunLoopSource if it matters
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [self] _ in refresh() }
    }

    // Every .mp4/.mov dropped in Videos/ shows up in the menu, titled by file name.
    func videos() -> [(title: String, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
            .sorted { $0.title < $1.title }
    }

    @objc func rebuild() {
        walls.forEach { $0.close() }
        walls = []
        guard let url else { return }
        walls = NSScreen.screens.map { Wall(screen: $0, url: url) }
        for w in walls {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w.window, queue: .main) { [self] _ in refresh() }
        }
        refresh()
    }

    func onBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPSBatteryPowerValue
    }

    // Play only when someone could actually see it.
    func refresh() {
        let allowed = !userPaused && !screensAsleep && !(pauseOnBattery && onBattery())
        for w in walls {
            // LIVEWALL_DEBUG=1 skips the occlusion check so playback can be tested under a full-screen window
            if allowed && (debug || w.window.occlusionState.contains(.visible)) { w.player.play() } else { w.player.pause() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for v in videos() {
            let mi = NSMenuItem(title: v.title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.representedObject = v.url; mi.target = self; mi.state = v.url == url ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let lock = NSMenuItem(title: "Lock screen", action: nil, keyEquivalent: ""); lock.submenu = NSMenu()
        for v in videos() {
            let mi = NSMenuItem(title: v.title, action: #selector(pickLock(_:)), keyEquivalent: "")
            mi.representedObject = v.url; mi.target = self; mi.state = v.url.path == defaults.string(forKey: "lockVideo") ? .on : .off
            lock.submenu?.addItem(mi)
        }
        menu.addItem(lock)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let folder = NSMenuItem(title: "Open videos folder", action: #selector(openFolder), keyEquivalent: ""); folder.target = self
        let other = NSMenuItem(title: "Choose file…", action: #selector(choose), keyEquivalent: ""); other.target = self
        let pause = NSMenuItem(title: userPaused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: ""); pause.target = self
        let bat = NSMenuItem(title: "Pause on battery", action: #selector(toggleBattery), keyEquivalent: ""); bat.target = self
        bat.state = pauseOnBattery ? .on : .off
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [folder, other, pause, bat, login, .separator(), quit].forEach(menu.addItem)
    }

    @objc func openFolder() { NSWorkspace.shared.open(videosDir) }

    func alert(_ text: String) { NSApp.activate(ignoringOtherApps: true); let a = NSAlert(); a.messageText = text; a.runModal() }

    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { alert("Launch at login failed: \(error.localizedDescription)") }
        if SMAppService.mainApp.status == .requiresApproval { alert("Allow LiveWall in System Settings ▸ General ▸ Login Items.") }
    }

    func setLock(_ u: URL) {
        do {
            let id = try LockScreen.apply(u, title: u.deletingPathExtension().lastPathComponent)
            defaults.set(u.path, forKey: "lockVideo"); defaults.set(id, forKey: "lockID")
        } catch { alert("Lock screen failed: \(error)") }
    }
    @objc func pickLock(_ s: NSMenuItem) { setLock(s.representedObject as! URL) }

    func set(_ u: URL) { url = u; defaults.set(u.path, forKey: "video"); rebuild() }
    @objc func pick(_ s: NSMenuItem) { set(s.representedObject as! URL) }
    @objc func choose() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { set(u) }
    }
    @objc func togglePause() { userPaused.toggle(); refresh() }
    @objc func toggleBattery() { pauseOnBattery.toggle(); refresh() }
}

// `LiveWall --lock <video>` sets the lock screen from the command line (used for testing) and exits.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--lock" {
    let u = URL(fileURLWithPath: CommandLine.arguments[2])
    do { print("ok", try LockScreen.apply(u, title: u.deletingPathExtension().lastPathComponent)); exit(0) }
    catch { print("failed:", error); exit(1) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

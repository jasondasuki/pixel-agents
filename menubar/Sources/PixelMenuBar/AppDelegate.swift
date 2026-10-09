import AppKit
import PixelMenuBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = AgentStore()
    private var renderer: LaneRenderer!
    private var menuBuilder: MenuBuilder!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let registry = Registry()
    private let token = randomToken()
    private var server: HookServer?
    private var serverError: String?

    private var tickTimer: Timer?
    private var expiryTimer: Timer?
    private var lastTick = Date()
    private var lastSignature = 0
    private var displayAsleep = false
    private var signalSources: [DispatchSourceSignal] = []
    /// Extra cap found by `checkFit`; nil until the item has been seen hidden.
    private var fitLimit: Double?
    private var lastLaneWidth = 0.0
    private var fitCheckPending = false
    private let debug = ProcessInfo.processInfo.environment["PIXEL_MENUBAR_DEBUG"] != nil

    private static let tickInterval: TimeInterval = 1.0 / 12
    private static let petDefaultsKey = "pet"
    private static let laneDefaultsKey = "laneWidth"
    /// The lane never takes more than this share of the main screen's width.
    private static let maxScreenShare = 0.4
    /// macOS hides a status item that does not fit (notch, app menus, system icons).
    /// `checkFit` shrinks the lane to what fits, but never below this.
    private static let minFitWidth = 96.0
    /// Measured on a notched MacBook: an item whose left edge is within ~22pt of the area macOS
    /// reports as usable (right of the notch) is still hidden. 28pt keeps clear of that.
    private static let fitMargin = 28.0

    private var choice: PetChoice {
        get { PetChoice(stored: UserDefaults.standard.string(forKey: Self.petDefaultsKey)) }
        set { UserDefaults.standard.set(newValue.stored, forKey: Self.petDefaultsKey) }
    }

    private var laneSetting: LaneSetting {
        get { LaneSetting(stored: UserDefaults.standard.object(forKey: Self.laneDefaultsKey) as? Double) }
        set { UserDefaults.standard.set(newValue.stored, forKey: Self.laneDefaultsKey) }
    }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let pets = PetLoader.loadAll()
        guard !pets.isEmpty else {
            log("no pet sprites found in \(PetLoader.resourceDirectory.path)")
            NSApp.terminate(nil)
            return
        }
        renderer = LaneRenderer(pets: pets)

        if let other = registry.cleanStale(), other.pid != Int(getpid()) {
            log("already running (pid \(other.pid))")
            NSApp.terminate(nil)
            return
        }

        startServer()
        installStatusItem()
        installSignalHandlers()
        observeDisplaySleep()
        observeFrontmostApp()

        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.store.expireStale().isEmpty else { return }
                self.refresh()
            }
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        registry.remove(pid: Int(getpid()))
    }

    private func startServer() {
        let server = HookServer(token: token) { [weak self] hook in
            MainActor.assumeIsolated {
                self?.store.apply(hook)
                self?.refresh()
            }
        }
        self.server = server
        server.start { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case let .success(port):
                        let entry = RegistryEntry(
                            port: port, pid: Int(getpid()), token: self.token,
                            startedAt: Int(Date().timeIntervalSince1970 * 1000)
                        )
                        do {
                            try self.registry.write(entry)
                            self.log("listening on 127.0.0.1:\(port)")
                        } catch {
                            self.serverError = "can't write registry: \(error.localizedDescription)"
                            self.log(self.serverError!)
                        }
                    case let .failure(error):
                        self.serverError = "hook listener failed: \(error.localizedDescription)"
                        self.log(self.serverError!)
                    }
                }
            }
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        menu.delegate = self
        statusItem.menu = menu
        menuBuilder = MenuBuilder(
            renderer: renderer,
            choice: { [unowned self] in self.choice },
            setChoice: { [unowned self] in self.choice = $0 },
            laneSetting: { [unowned self] in self.laneSetting },
            target: self,
            openFolderAction: #selector(openFolder),
            quitAction: #selector(quit),
            pickPetAction: #selector(pickPet(_:)),
            pickLaneAction: #selector(pickLane(_:))
        )
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func observeFrontmostApp() {
        let center = NSWorkspace.shared.notificationCenter
        // The frontmost app's menus take room from the left; re-measure instead of resetting, so the lane
        // does not flash wide and back each time you switch apps.
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFitCheck() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetFit() }
        }
    }

    private func observeDisplaySleep() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displayAsleep = true; self?.updateTimer() }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displayAsleep = false; self?.updateTimer() }
            }
        }
    }

    // MARK: drawing

    private var barHeight: Double { Double(NSStatusBar.system.thickness) }

    private func currentLaneWidth(agentCount: Int) -> Double {
        let screen = NSScreen.main?.frame.width ?? 1440
        let limit = min(screen * Self.maxScreenShare, fitLimit ?? .infinity)
        return laneWidth(agentCount: agentCount, setting: laneSetting, screenLimit: limit)
    }

    /// Redraws now and starts or stops the animation clock to match the agent count.
    private func refresh() {
        let agents = store.sorted()
        let width = currentLaneWidth(agentCount: agents.count)
        // Pets that just arrived need a position before their first frame.
        renderer.step(dt: 0, agents: agents, now: Date(), laneWidth: width)
        draw(agents: agents, width: width)
        updateTimer()
    }

    private func draw(agents: [Agent], width: Double) {
        let now = Date()
        if width != lastLaneWidth {
            lastLaneWidth = width
            scheduleFitCheck()
        }
        lastSignature = renderer.signature(agents: agents, now: now, laneWidth: width)
        statusItem.button?.image = renderer.image(agents: agents, choice: choice, now: now, laneWidth: width, barHeight: barHeight)
    }

    /// Pets always wander, so the clock runs whenever any agent exists, except while the
    /// display sleeps. With no agents the sleeping pet is static and nothing ticks.
    private func updateTimer() {
        let shouldRun = !store.agents.isEmpty && !displayAsleep
        if shouldRun, tickTimer == nil {
            lastTick = Date()
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = Self.tickInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !shouldRun, let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        let now = Date()
        let dt = min(0.25, now.timeIntervalSince(lastTick))
        lastTick = now
        // Menu bar hidden (full-screen app, locked screen): keep time moving, skip drawing.
        guard statusItem.button?.window?.occlusionState.contains(.visible) ?? true else { return }

        let agents = store.sorted()
        let width = currentLaneWidth(agentCount: agents.count)
        renderer.step(dt: dt, agents: agents, now: now, laneWidth: width)
        let signature = renderer.signature(agents: agents, now: now, laneWidth: width)
        guard signature != lastSignature else { return }
        draw(agents: agents, width: width)
    }

    // MARK: fit

    /// Layout is asynchronous; look once it has settled.
    private func scheduleFitCheck() {
        guard !fitCheckPending else { return }
        fitCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.fitCheckPending = false
                self?.checkFit()
            }
        }
    }

    /// How far the item's window sticks out past the part of the menu bar it may use, in points
    /// (negative = spare room). On a notched display status items live right of the notch, so that
    /// area (not the whole screen) is the limit; the item sits right-aligned against the system icons,
    /// so overflow shows up on its left edge.
    private func excess() -> Double? {
        guard let window = statusItem.button?.window else { return nil }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let usable = screen.safeAreaInsets.top > 0 ? (screen.auxiliaryTopRightArea ?? screen.frame) : screen.frame
        let f = window.frame
        guard window.occlusionState.contains(.visible) else { return 0.2 * lastLaneWidth }
        return Double(max(usable.minX + Self.fitMargin - f.minX, f.maxX - usable.maxX))
    }

    private func wantedLaneWidth() -> Double {
        let screen = NSScreen.main?.frame.width ?? 1440
        return laneWidth(agentCount: store.agents.count, setting: laneSetting, screenLimit: screen * Self.maxScreenShare)
    }

    private func checkFit() {
        guard !store.agents.isEmpty, let excess = excess() else { return }
        if debug {
            let f = statusItem.button?.window?.frame ?? .zero
            log("fit: lane=\(Int(lastLaneWidth)) excess=\(Int(excess)) limit=\(fitLimit.map { Int($0) } ?? -1) frame=\(f)")
        }
        if excess > 0.5, lastLaneWidth > Self.minFitWidth {
            // Take off exactly what overflows, plus a little slack for the item's own padding.
            fitLimit = max(Self.minFitWidth, lastLaneWidth - excess - 4)
            log("status item hidden at \(Int(lastLaneWidth))pt; shrinking lane to \(Int(fitLimit!))pt")
            refresh()   // width changed, so draw() schedules the next check
        } else if fitLimit != nil, -excess > 12, lastLaneWidth < wantedLaneWidth() - 0.5 {
            // The first reading can come from an item that has not been placed yet and over-shrink; use spare room.
            let grown = lastLaneWidth - excess - 4
            fitLimit = grown >= wantedLaneWidth() ? nil : grown
            refresh()
        }
    }

    /// Setting or screen changed: forget what was learned and re-check from the wanted width.
    private func resetFit() {
        fitLimit = nil
        refresh()
        scheduleFitCheck()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuBuilder.rebuild(menu, agents: store.sorted())
        if let serverError {
            let item = NSMenuItem(title: serverError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 1)
        }
    }

    @objc private func openFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pixel-agents")
        NSWorkspace.shared.open(dir)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pickPet(_ sender: NSMenuItem) {
        choice = PetChoice(stored: sender.representedObject as? String)
        refresh()
    }

    @objc private func pickLane(_ sender: NSMenuItem) {
        laneSetting = LaneSetting(stored: (sender.representedObject as? NSNumber)?.doubleValue)
        resetFit()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[PixelMenuBar] \(message)\n".utf8))
    }
}

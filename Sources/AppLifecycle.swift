import AppKit

extension AppDelegate {
    func buildApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let menu = NSMenu()
        for (title, action, key) in [
            ("Open Tailbar", #selector(showDashboard(_:)), "0"),
            ("Settings…", #selector(showSettingsWindow(_:)), ","),
            ("Hide Tailbar", #selector(NSApplication.hide(_:)), "h"),
            ("Quit", #selector(quitApp(_:)), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = action == #selector(NSApplication.hide(_:)) ? NSApp : self
            menu.addItem(item)
        }
        application.submenu = menu
        let statusMenu = NSMenuItem(title: "Open Menu Bar", action: #selector(showStatusMenu(_:)), keyEquivalent: "m")
        statusMenu.keyEquivalentModifierMask = [.command, .shift]
        statusMenu.target = self
        menu.insertItem(statusMenu, at: 1)
        main.addItem(application)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc func showDashboard(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        if dashboard == nil {
            let controller = DashboardController()
            controller.onConnect = { [weak self] in
                guard let self = self else { return }
                if self.currentPrefs?.LoggedOut == true || self.currentStatus?.backendState == "NeedsLogin" {
                    self.startConnectOrLogin()
                } else { self.toggleConnection(NSMenuItem()) }
            }
            controller.onExit = { [weak self] target in
                let item = NSMenuItem()
                item.representedObject = target
                self?.selectExitNode(item)
            }
            controller.onHideDock = { value in UserDefaults.standard.set(value, forKey: "hideDockWhenClosed") }
            controller.onPing = { [weak self] ip in
                let item = NSMenuItem(); item.representedObject = ip; self?.pingPeer(item)
            }
            controller.onPreference = { [weak self] key in
                let item = NSMenuItem(); item.representedObject = key; self?.togglePref(item)
            }
            controller.onLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin(NSMenuItem()) }
            controller.onReconnectAcrossSleep = { [weak self] value in self?.reconnectAcrossSleep = value }
            controller.onReconnect = { [weak self] in self?.reconnectTailscale(nil) }
            controller.model.reconnectAcrossSleep = reconnectAcrossSleep
            controller.onAutoRepair = { [weak self] value in
                self?.autoRepairNetwork = value
                if value { self?.checkNetworkHealth() }
            }
            controller.onRepairNetwork = { [weak self] in self?.repairNetwork(nil) }
            controller.model.autoRepair = autoRepairNetwork
            controller.onAccount = { [weak self] in
                self?.buildAccountMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
            controller.onClose = {
                if UserDefaults.standard.bool(forKey: "hideDockWhenClosed") { NSApp.setActivationPolicy(.accessory) }
            }
            dashboard = controller
        }
        updateDashboard()
        dashboard?.showWindow(nil)
        dashboard?.window?.deminiaturize(nil)
        dashboard?.window?.makeKeyAndOrderFront(nil)
        dashboard?.window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard(nil)
        refresh()
        return false
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        showDashboard(nil)
        dashboard?.showSettings()
    }

    @objc func showStatusMenu(_ sender: Any?) {
        statusItem.button?.performClick(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        timer?.invalidate()
        healthTimer?.invalidate()
        stopAnimating()
        eventRefresh?.cancel()
        eventPipe?.fileHandleForReading.readabilityHandler = nil
        // This is only our read-only subscription CLI, never the VPN daemon.
        if let process = eventProcess, process.isRunning { process.terminate() }
    }

    func updateDashboard() {
        dashboard?.model.transport = clientTransport
        dashboard?.model.networkHealth = networkHealth.line
        dashboard?.update(status: currentStatus, prefs: currentPrefs,
                          busy: loginInProgress || commandInProgress || repairingNetwork,
                          proxy: proxyStatus, route: routeStatus)
    }

    func startEventWatcher() {
        guard !terminating, eventProcess == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailscaleBin)
        process.arguments = ["--socket=\(tailscaleSocket)", "debug", "watch-ipn", "--initial", "--peer-changes=false", "--peer-patches=false"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        eventParser = JSONObjectStream()
        eventProcess = process
        eventPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self = self, self.eventProcess === process, !self.terminating else { return }
                let events = self.eventParser.feed(data)
                for event in events {
                    if let state = event["State"] as? Int {
                        let names = ["NoState", "InUseOtherUser", "NeedsLogin", "NeedsMachineAuth", "Stopped", "Starting", "Running"]
                        if names.indices.contains(state) {
                            self.stateRevision += 1
                            self.currentStatus?.backendState = names[state]
                            // Do not wait for the slower full snapshot to start/stop animation.
                            if state == 5 { self.startAnimatingIfNeeded() }
                            else { self.updateIcon(status: self.currentStatus) }
                            self.updateDashboard()
                        }
                    }
                }
                guard !events.isEmpty else { return }
                self.eventRefresh?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                self.eventRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.eventProcess === process else { return }
                self.eventPipe?.fileHandleForReading.readabilityHandler = nil
                self.eventProcess = nil
                self.eventPipe = nil
                guard !self.terminating else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startEventWatcher() }
            }
        }
        do { try process.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            eventProcess = nil
            eventPipe = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startEventWatcher() }
        }
    }

    /// Local route lookup, not a reachability test and not a public-IP request.
    func readRouteStatus(_ status: TSStatus?) -> String {
        guard status?.backendState == "Running", status?.exitNodeStatus?.ID != nil else {
            return "No exit node in use"
        }
        func output(_ path: String, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
        let route = output("/sbin/route", ["-n", "get", "203.0.113.1"])
        guard let line = route.split(separator: "\n").first(where: { $0.contains("interface:") }),
              let iface = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              iface.hasPrefix("utun") else {
            return "⚠ Exit node selected, but the test IPv4 route does not go through Tailscale"
        }
        let addresses = status?.selfNode?.TailscaleIPs ?? []
        let config = output("/sbin/ifconfig", [iface])
        let matches = config.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.count > 1 && fields[0] == "inet" && addresses.contains(String(fields[1]))
        }
        return matches ? "IPv4 route → Tailscale (\(iface)) · reachability not tested" : "⚠ Test IPv4 route goes through another VPN (\(iface))"
    }
}

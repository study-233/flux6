import AppKit

@MainActor
final class HostMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private weak var app: HostApplication?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let connectionMenu = NSMenu()
    private var state: [String: Any] = [:]
    private var presentedStatus: String?
    private var appearanceKey: String?
    private var initialized = false

    init(app: HostApplication) { self.app = app }

    func install() {
        guard let bar = NSApp.mainMenu, let appMenu = bar.items.first?.submenu else { return }
        let settingsID = NSUserInterfaceItemIdentifier("dev.freev6.menu.settings")
        if !appMenu.items.contains(where: { $0.identifier == settingsID }) {
            let settings = item("设置…", "settings", key: ",")
            settings.identifier = settingsID
            appMenu.insertItem(settings, at: min(2, appMenu.items.count))
        }
        if initialized, ["文件", "导航", "连接"].allSatisfy({ title in bar.items.contains { $0.title == title } }) { return }
        // The nib's text-system Find panel otherwise wins Cmd-F before the
        // navigation menu can focus the Flutter node search.
        relinquishTextFindShortcut(in: bar)
        let files = NSMenu()
        files.addItem(item("导入配置…", "import", key: "o"))
        files.addItem(item("保存修改", "save", key: "s"))
        install(files, named: "文件", at: 1, bar: bar)
        let pages = NSMenu()
        for (index, pair) in [("仪表盘", "dashboard"), ("节点", "nodes"), ("配置", "config"), ("日志", "logs")].enumerated() {
            pages.addItem(item(pair.0, "goto", key: String(index + 1), args: ["page": pair.1]))
        }
        pages.addItem(.separator())
        pages.addItem(item("查找", "find", key: "f"))
        pages.addItem(.separator())
        pages.addItem(item("编辑首页布局…", "editLayout"))
        pages.addItem(item("公告…", "showNotices"))
        install(pages, named: "导航", at: 3, bar: bar)
        connectionMenu.delegate = self
        install(connectionMenu, named: "连接", at: 4, bar: bar)
        statusMenu.delegate = self
        let prefs = UserDefaults.standard
        if !initialized {
            initialized = true
            apply(["settings": ["preferences": ["showMenuBar": prefs.object(forKey: "showMenuBarExtra") as? Bool ?? true,
                                                 "appearance": prefs.string(forKey: "appearance") ?? "system"]]])
        }
    }

    private func relinquishTextFindShortcut(in menu: NSMenu) {
        for item in menu.items {
            if item.keyEquivalent == "f", item.keyEquivalentModifierMask == .command,
               item.action == NSSelectorFromString("performFindPanelAction:") {
                item.keyEquivalent = ""
            }
            if let child = item.submenu { relinquishTextFindShortcut(in: child) }
        }
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        presentedStatus = nil
    }

    private func install(_ menu: NSMenu, named title: String, at index: Int, bar: NSMenu) {
        let id = NSUserInterfaceItemIdentifier("dev.freev6.menu." + title)
        if bar.items.contains(where: { $0.identifier == id }) { return }
        menu.title = title
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.identifier = id
        root.submenu = menu
        bar.insertItem(root, at: min(index, bar.items.count))
    }

    func apply(_ value: [String: Any]) {
        state = value
        let preferences = (value["settings"] as? [String: Any])?["preferences"] as? [String: Any]
        let appearance = preferences?["appearance"] as? String ?? "system"
        if appearanceKey != appearance {
            appearanceKey = appearance
            switch appearance {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        }
        if preferences?["showMenuBar"] as? Bool == false {
            if statusItem != nil, app?.main?.window?.isVisible == false, app?.settings?.window?.isVisible != true { app?.showMain() }
            remove()
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.menu = statusMenu
        }
        guard phaseLabel != presentedStatus else { return }
        presentedStatus = phaseLabel
        let symbol = state["phase"] as? String == "running" ? "bolt.shield.fill" : "shield"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FreeV6，" + phaseLabel)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "FreeV6 · " + phaseLabel
    }

    private var phaseLabel: String {
        switch state["phase"] as? String {
        case "running": return "已连接"
        case "idle": return "未连接"
        case "connecting": return "正在连接"
        case "disconnecting": return "正在断开"
        case "recovering": return "需要恢复"
        case "occupied": return "其他会话占用"
        default: return "正在检查"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        if menu === statusMenu {
            menu.addItem(item("打开 FreeV6", "main"))
            menu.addItem(.separator())
        }
        let status = NSMenuItem(title: phaseLabel, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let caps = state["capabilities"] as? [String: Any] ?? [:]
        let phase = state["phase"] as? String
        let accepted = (state["settings"] as? [String: Any])?["accepted"] as? Bool == true
        let needsPreparation = ["missing", "needsRepair"].contains(state["service"] as? String ?? "")
        let name = phase == "running" ? "disconnect" : phase == "recovering" ? "retryRecovery" : needsPreparation ? "prepareService" : "connect"
        let action = item(["disconnect":"断开", "retryRecovery":"重试恢复", "prepareService":"准备网络服务…"][name] ?? "连接", "command", args: ["name": name])
        action.isEnabled = caps[name] as? Bool == true || (phase == "recovering" && (caps["disconnect"] as? Bool == true || caps["recover"] as? Bool == true))
        if name == "prepareService" { action.isEnabled = accepted && action.isEnabled }
        menu.addItem(action)
        let modes = NSMenu()
        modes.autoenablesItems = false
        for (title, mode) in [("规则", "rule"), ("全局", "global"), ("直连", "direct")] {
            let button = item(title, "command", args: ["name": "setMode", "mode": mode])
            button.state = state["mode"] as? String == mode ? .on : .off
            button.isEnabled = caps["mode"] as? Bool == true
            modes.addItem(button)
        }
        let modeRoot = NSMenuItem(title: "工作模式", action: nil, keyEquivalent: "")
        modeRoot.submenu = modes
        menu.addItem(modeRoot)
        let nodes = NSMenu(); nodes.autoenablesItems = false
        let automatic = item("自动选择", "command", args: ["name": "setNode", "group": "access", "node": NSNull()])
        let preferred = state["preferredNode"] as? String
        automatic.state = preferred == nil ? .on : .off
        automatic.isEnabled = caps["node"] as? Bool == true
        nodes.addItem(automatic)
        let members = state["nodes"] as? [String] ?? []
        for node in members.prefix(10) {
            let button = item(node, "command", args: ["name": "setNode", "group": "access", "node": node])
            button.state = preferred == node ? .on : .off
            button.isEnabled = caps["node"] as? Bool == true
            nodes.addItem(button)
        }
        nodes.addItem(.separator())
        nodes.addItem(item("全部接入节点…", "goto", args: ["page": "nodes"]))
        let nodeRoot = NSMenuItem(title: "接入节点", action: nil, keyEquivalent: "")
        nodeRoot.submenu = nodes
        menu.addItem(nodeRoot)
        if menu === connectionMenu {
            menu.addItem(.separator())
            let prepare = item("服务与恢复…", "showPreparation")
            prepare.isEnabled = accepted
            menu.addItem(prepare)
            let refresh = item("刷新状态", "command", args: ["name": "refresh"])
            refresh.isEnabled = accepted
            menu.addItem(refresh)
            if state["environment"] as? String == "isolated" {
                let scenarios = item("隔离验收场景…", "showScenarios")
                scenarios.isEnabled = accepted
                menu.addItem(scenarios)
            }
        }
        if menu === statusMenu {
            menu.addItem(.separator())
            menu.addItem(item("设置…", "settings"))
            menu.addItem(item("退出 FreeV6", "quit"))
        }
    }

    private func item(_ title: String, _ action: String, key: String = "", args: [String: Any] = [:]) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: #selector(performItem(_:)), keyEquivalent: key)
        result.target = self
        var object: [String: Any] = ["action": action, "args": args]
        if action == "command" {
            var context: [String: Any] = [:]
            for key in ["sessionId", "revision", "sessionRevision", "controlToken"] {
                context[key] = state[key] ?? NSNull()
            }
            object["context"] = context
        }
        result.representedObject = object
        return result
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = (menuItem.representedObject as? [String: Any])?["action"] as? String
        if action == "editLayout" || action == "showNotices" {
            return (state["settings"] as? [String: Any])?["accepted"] as? Bool == true
        }
        return true
    }

    @objc private func performItem(_ sender: NSMenuItem) {
        guard let app, let object = sender.representedObject as? [String: Any], let action = object["action"] as? String else { return }
        var args = object["args"] as? [String: Any] ?? [:]
        switch action {
        case "main": app.showMain()
        case "settings": app.showSettings()
        case "quit": app.requestQuit()
        case "editLayout", "showNotices", "showPreparation", "showScenarios":
            app.showMain()
            app.main?.uiAction(action)
        case "goto": app.showMain(); app.main?.uiAction(action, args: args)
        case "command":
            guard let name = args.removeValue(forKey: "name") as? String else { return }
            let displayed = object["context"] as? [String: Any]
            Task { await app.runCommand(name, args: args, displayedContext: displayed) }
        default: app.focused?.uiAction(action, args: args)
        }
    }
}

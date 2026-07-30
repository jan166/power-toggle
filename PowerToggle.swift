// PowerToggle: a small menu bar app for two sleep-related macOS settings.
//
//   - Lid-close sleep prevention (pmset disablesleep)
//   - A caffeinate blocking mode (~/.config/caffeinate-toggle/mode, shared with the shim)
//
// Changing pmset needs root. If the sudoers NOPASSWD rule is installed it applies
// instantly, otherwise it falls back to the standard macOS authentication dialog.
//
// The UI follows the system language: Korean when the preferred language is Korean,
// English otherwise. Test the English strings with:
//   ~/Applications/PowerToggle.app/Contents/MacOS/PowerToggle -AppleLanguages '(en)'

import Cocoa

// MARK: - Localization

/// Follows the system language, unless pinned explicitly:
///   defaults write com.hyoju.powertoggle language -string ko
///   defaults write com.hyoju.powertoggle language -string en
let isKorean: Bool = {
	if let forced = UserDefaults.standard.string(forKey: "language")?.lowercased() {
		if forced.hasPrefix("ko") { return true }
		if forced.hasPrefix("en") { return false }
	}
	return (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
}()

/// Picks the Korean or English string for the current system language.
func t(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

// MARK: - Running commands

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
	let task = Process()
	task.executableURL = URL(fileURLWithPath: path)
	task.arguments = args
	let outPipe = Pipe()
	task.standardOutput = outPipe
	task.standardError = FileHandle.nullDevice
	do { try task.run() } catch { return (-1, "") }
	let data = outPipe.fileHandleForReading.readDataToEndOfFile()
	task.waitUntilExit()
	return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Runs a command as root. Tries sudo -n first (instant with the sudoers rule),
/// then falls back to the macOS administrator authentication dialog.
func runElevated(_ argv: [String]) -> Bool {
	if shell("/usr/bin/sudo", ["-n"] + argv).status == 0 { return true }
	let joined = argv.map { "'\($0)'" }.joined(separator: " ")
	let script = "do shell script \"\(joined)\" with administrator privileges"
	return shell("/usr/bin/osascript", ["-e", script]).status == 0
}

// MARK: - Reading state

let sudoersRulePath = "/etc/sudoers.d/pmset-lid-toggle"
let sudoersSourcePath = NSHomeDirectory() + "/.config/caffeinate-toggle/pmset-lid-toggle.sudoers"
let caffeinateModePath = NSHomeDirectory() + "/.config/caffeinate-toggle/mode"
let caffeinateShimPath = NSHomeDirectory() + "/.local/bin/caffeinate"

struct PowerState {
	var lidPrevention = false      // stays awake with the lid closed
	var displaySleep = "?"         // minutes until the display turns off
	var powerSource = "?"
	var batteryPercent = ""
	var caffeinateMode = "on"
	var caffeinateRunning = 0
	var shimInstalled = false
	var sudoersInstalled = false

	static func read() -> PowerState {
		var s = PowerState()

		for raw in shell("/usr/bin/pmset", ["-g"]).out.split(separator: "\n") {
			let f = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
			guard f.count >= 2 else { continue }
			if f[0] == "SleepDisabled" { s.lidPrevention = (f[1] == "1") }
			if f[0] == "displaysleep" { s.displaySleep = f[1] }
		}

		let batt = shell("/usr/bin/pmset", ["-g", "batt"]).out
		if let open = batt.range(of: "drawing from '"),
		   let close = batt.range(of: "'", range: open.upperBound ..< batt.endIndex) {
			s.powerSource = String(batt[open.upperBound ..< close.lowerBound])
		}
		if let pct = batt.range(of: "[0-9]{1,3}%", options: .regularExpression) {
			s.batteryPercent = String(batt[pct])
		}

		let fm = FileManager.default
		s.shimInstalled = fm.fileExists(atPath: caffeinateShimPath)
		s.sudoersInstalled = fm.fileExists(atPath: sudoersRulePath)

		if let raw = try? String(contentsOfFile: caffeinateModePath, encoding: .utf8) {
			let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			if !m.isEmpty { s.caffeinateMode = m }
		} else if s.shimInstalled {
			s.caffeinateMode = "auto"
		}

		let pg = shell("/usr/bin/pgrep", ["-x", "caffeinate"]).out
		s.caffeinateRunning = pg.split(separator: "\n").filter { !$0.isEmpty }.count

		return s
	}

	var onBattery: Bool { !powerSource.contains("AC") }

	/// One line saying whether the machine can actually sleep right now.
	var verdict: String {
		if lidPrevention {
			return t("닫아도 안 잠듦. 배터리 소모 큼",
			         "Stays awake with the lid closed. Heavy battery drain")
		}
		let blocked = caffeinateMode == "off" || (caffeinateMode == "auto" && onBattery)
		if !blocked && caffeinateRunning > 0 {
			return t("닫으면 잠듦 (caffeinate가 유휴 잠들기를 막고 있음)",
			         "Sleeps on lid close (caffeinate is blocking idle sleep)")
		}
		return t("닫으면 잠듦. 배터리 절약 중", "Sleeps on lid close. Saving battery")
	}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private var statusItem: NSStatusItem!
	private var state = PowerState()
	private var timer: Timer?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)

		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		// autosaveName is what makes the position persist. Without it macOS can park
		// the item on the notch boundary where it gets clipped. Command-drag is the
		// only reliable way to move it; writing the preferred-position key is ignored.
		statusItem.autosaveName = "PowerToggle"
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		refresh()
		timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
			self?.refresh()
		}

		// Record where the status item landed, so a missing icon can be diagnosed.
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
			guard let window = self.statusItem.button?.window else { return }
			let visible = window.occlusionState == .visible
			let info = "x=\(window.frame.origin.x) w=\(window.frame.width) " +
				"occlusion=\(visible ? "VISIBLE" : "hidden") " +
				"img=\(self.statusItem.button?.image != nil)"
			try? info.write(toFile: "/tmp/pt-diag.log", atomically: true, encoding: .utf8)
			if !visible {
				NSLog("PowerToggle: status item is not visible (%@)", info)
			}
		}
	}

	private func refresh() {
		state = .read()
		guard let button = statusItem.button else { return }
		let symbol = state.lidPrevention ? "bolt.fill" : "moon.zzz.fill"
		let label = state.lidPrevention
			? t("잠들기 방지 켜짐", "Sleep prevention on")
			: t("잠들기 허용", "Sleep allowed")
		let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
		image?.isTemplate = true
		button.image = image
		// With no image the item would be zero width and invisible, so fall back to text.
		button.title = (image == nil) ? (state.lidPrevention ? "⚡︎" : "☾") : ""
		button.imagePosition = image == nil ? .noImage : .imageOnly
		button.toolTip = "PowerToggle: \(state.verdict)"
	}

	// MARK: Menu

	func menuNeedsUpdate(_ menu: NSMenu) {
		state = .read()
		menu.removeAllItems()

		addInfo(menu, t("지금: \(state.verdict)", "Now: \(state.verdict)"))
		menu.addItem(.separator())

		let lid = NSMenuItem(title: t("뚜껑 닫아도 안 잠들기", "Stay awake with lid closed"),
		                     action: #selector(toggleLid), keyEquivalent: "")
		lid.target = self
		lid.state = state.lidPrevention ? .on : .off
		menu.addItem(lid)

		let cafItem = NSMenuItem(title: t("caffeinate (작업 중 유휴 잠들기 방지)",
		                                  "caffeinate (blocks idle sleep during work)"),
		                         action: nil, keyEquivalent: "")
		let cafMenu = NSMenu()
		let modes = [("on", t("항상 허용 (macOS 기본)", "Always allow (stock macOS)")),
		             ("auto", t("전원 연결 시만 허용", "Allow on AC power only")),
		             ("off", t("항상 차단", "Always block"))]
		for (mode, title) in modes {
			let item = NSMenuItem(title: title, action: #selector(setCaffeinate(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = mode
			item.state = (state.caffeinateMode == mode) ? .on : .off
			cafMenu.addItem(item)
		}
		if !state.shimInstalled {
			cafMenu.addItem(.separator())
			addInfo(cafMenu, t("shim 미설치. ~/.local/bin/caffeinate 필요",
			                   "Shim not installed. Needs ~/.local/bin/caffeinate"))
		}
		cafItem.submenu = cafMenu
		menu.addItem(cafItem)

		menu.addItem(.separator())
		addInfo(menu, t("화면 꺼짐   \(state.displaySleep)분",
		                "Display off   \(state.displaySleep) min"))
		let power = state.powerSource + (state.batteryPercent.isEmpty ? "" : "  (\(state.batteryPercent))")
		addInfo(menu, t("전원        \(power)", "Power         \(power)"))
		addInfo(menu, t("caffeinate  \(state.caffeinateRunning)개 실행 중",
		                "caffeinate  \(state.caffeinateRunning) running"))

		menu.addItem(.separator())
		if !state.sudoersInstalled && FileManager.default.fileExists(atPath: sudoersSourcePath) {
			let item = NSMenuItem(title: t("비밀번호 없이 토글하기 설정…",
			                               "Set up passwordless toggling…"),
			                      action: #selector(installSudoers), keyEquivalent: "")
			item.target = self
			menu.addItem(item)
		}
		let login = NSMenuItem(title: t("로그인 시 자동 실행", "Launch at login"),
		                       action: #selector(toggleLoginItem), keyEquivalent: "")
		login.target = self
		login.state = LoginItem.isEnabled ? .on : .off
		menu.addItem(login)

		let quit = NSMenuItem(title: t("PowerToggle 종료", "Quit PowerToggle"),
		                      action: #selector(quit), keyEquivalent: "q")
		quit.target = self
		menu.addItem(quit)
	}

	private func addInfo(_ menu: NSMenu, _ title: String) {
		let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		item.isEnabled = false
		item.attributedTitle = NSAttributedString(string: title, attributes: [
			.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
			.foregroundColor: NSColor.secondaryLabelColor,
		])
		menu.addItem(item)
	}

	// MARK: Actions

	@objc private func toggleLid() {
		let next = state.lidPrevention ? "0" : "1"
		if runElevated(["/usr/bin/pmset", "-a", "disablesleep", next]) {
			refresh()
		} else {
			alert(t("설정을 바꾸지 못했습니다", "Could not change the setting"),
			      t("관리자 인증이 취소되었거나 실패했습니다. 터미널에서 직접 실행해도 됩니다:\n\nsudo pmset -a disablesleep \(next)",
			        "Authentication was cancelled or failed. You can run this yourself:\n\nsudo pmset -a disablesleep \(next)"))
		}
	}

	@objc private func setCaffeinate(_ sender: NSMenuItem) {
		guard let mode = sender.representedObject as? String else { return }
		let dir = (caffeinateModePath as NSString).deletingLastPathComponent
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		do {
			try (mode + "\n").write(toFile: caffeinateModePath, atomically: true, encoding: .utf8)
		} catch {
			alert(t("모드를 저장하지 못했습니다", "Could not save the mode"), error.localizedDescription)
			return
		}
		if mode != "on" { shell("/usr/bin/pkill", ["-x", "caffeinate"]) }
		refresh()
	}

	@objc private func installSudoers() {
		let ok = runElevated(["/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "440",
		                      sudoersSourcePath, sudoersRulePath])
		if ok {
			alert(t("설정 완료", "Done"),
			      t("이제 뚜껑 닫힘 방지 토글이 비밀번호 없이 바로 적용됩니다.\n\n되돌리려면: sudo rm \(sudoersRulePath)",
			        "Lid-close toggling now applies without a password.\n\nTo undo: sudo rm \(sudoersRulePath)"))
		} else {
			alert(t("설치하지 못했습니다", "Install failed"),
			      t("관리자 인증이 취소되었거나 실패했습니다.",
			        "Authentication was cancelled or failed."))
		}
		refresh()
	}

	@objc private func toggleLoginItem() {
		LoginItem.set(!LoginItem.isEnabled, executable: Bundle.main.executablePath)
	}

	@objc private func quit() { NSApp.terminate(nil) }

	private func alert(_ title: String, _ text: String) {
		let a = NSAlert()
		a.messageText = title
		a.informativeText = text
		a.alertStyle = .informational
		a.addButton(withTitle: t("확인", "OK"))
		NSApp.activate(ignoringOtherApps: true)
		a.runModal()
	}
}

// MARK: - Login item (LaunchAgent)

enum LoginItem {
	static let label = "com.hyoju.powertoggle"
	static var plistPath: String {
		NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
	}

	static var isEnabled: Bool {
		FileManager.default.fileExists(atPath: plistPath)
	}

	static func set(_ enabled: Bool, executable: String?) {
		let uid = getuid()
		let target = "gui/\(uid)"
		shell("/bin/launchctl", ["bootout", "\(target)/\(label)"])

		guard enabled, let exe = executable else {
			try? FileManager.default.removeItem(atPath: plistPath)
			return
		}

		let plist: [String: Any] = [
			"Label": label,
			"ProgramArguments": [exe],
			"RunAtLoad": true,
			"KeepAlive": false,
			"ProcessType": "Interactive",
		]
		let dir = (plistPath as NSString).deletingLastPathComponent
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
		                                                  format: .xml, options: 0) {
			try? data.write(to: URL(fileURLWithPath: plistPath))
			shell("/bin/launchctl", ["bootstrap", target, plistPath])
		}
	}
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

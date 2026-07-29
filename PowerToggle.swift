// PowerToggle — macOS 메뉴바에서 잠들기 관련 설정을 토글하는 작은 앱.
//
//   · 뚜껑 닫아도 안 잠들기 (pmset disablesleep)
//   · caffeinate 차단 모드   (~/.config/caffeinate-toggle/mode, caffeinate shim과 공유)
//
// 권한이 필요한 pmset 변경은 sudoers NOPASSWD 규칙이 있으면 즉시 실행하고,
// 없으면 macOS 표준 관리자 인증창으로 폴백한다.

import Cocoa

// MARK: - 셸 실행

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

/// root 권한 실행. 1) sudo -n (sudoers 규칙 있으면 즉시) 2) 관리자 인증창 폴백
func runElevated(_ argv: [String]) -> Bool {
	if shell("/usr/bin/sudo", ["-n"] + argv).status == 0 { return true }
	let joined = argv.map { "'\($0)'" }.joined(separator: " ")
	let script = "do shell script \"\(joined)\" with administrator privileges"
	return shell("/usr/bin/osascript", ["-e", script]).status == 0
}

// MARK: - 상태 읽기

let sudoersRulePath = "/etc/sudoers.d/pmset-lid-toggle"
let sudoersSourcePath = NSHomeDirectory() + "/.config/caffeinate-toggle/pmset-lid-toggle.sudoers"
let caffeinateModePath = NSHomeDirectory() + "/.config/caffeinate-toggle/mode"
let caffeinateShimPath = NSHomeDirectory() + "/.local/bin/caffeinate"

struct PowerState {
	var lidPrevention = false      // 뚜껑 닫아도 안 잠듦
	var displaySleep = "?"         // 화면 꺼지는 시간(분)
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

	/// 지금 실제로 잠들 수 있는 상태인지 한 줄 요약
	var verdict: String {
		if lidPrevention { return "닫아도 안 잠듦 — 배터리 소모 큼" }
		let blocked = caffeinateMode == "off" || (caffeinateMode == "auto" && onBattery)
		if !blocked && caffeinateRunning > 0 { return "닫으면 잠듦 (지금 caffeinate가 유휴 잠들기 방지 중)" }
		return "닫으면 잠듦 — 배터리 절약 중"
	}
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private var statusItem: NSStatusItem!
	private var state = PowerState()
	private var timer: Timer?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)

		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		// autosaveName이 있어야 위치가 저장/복원된다. 없으면 macOS가 노치 경계에 배치해
		// 항목이 가려질 수 있다. 희망 x좌표는 아래 키로 지정한다:
		//   defaults write com.hyoju.powertoggle "NSStatusItem Preferred Position PowerToggle" -int 1500
		statusItem.autosaveName = "PowerToggle"
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		refresh()
		timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
			self?.refresh()
		}

		// 메뉴바에 자리가 없어 항목이 노치 뒤/화면 밖으로 밀렸는지 진단해 남긴다.
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
			guard let window = self.statusItem.button?.window else { return }
			let visible = window.occlusionState == .visible
			let info = "x=\(window.frame.origin.x) w=\(window.frame.width) " +
				"occlusion=\(visible ? "VISIBLE" : "hidden") " +
				"img=\(self.statusItem.button?.image != nil)"
			try? info.write(toFile: "/tmp/pt-diag.log", atomically: true, encoding: .utf8)
			if !visible {
				NSLog("PowerToggle: 상태 항목이 보이지 않습니다 (%@)", info)
			}
		}
	}

	private func refresh() {
		state = .read()
		guard let button = statusItem.button else { return }
		let symbol = state.lidPrevention ? "bolt.fill" : "moon.zzz.fill"
		let label = state.lidPrevention ? "잠들기 방지 켜짐" : "잠들기 허용"
		let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
		image?.isTemplate = true
		button.image = image
		// 아이콘이 없으면(심볼 로드 실패) 항목이 0폭이 되어 아예 안 보이므로 텍스트로 대체
		button.title = (image == nil) ? (state.lidPrevention ? "⚡︎" : "☾") : ""
		button.imagePosition = image == nil ? .noImage : .imageOnly
		button.toolTip = "PowerToggle — \(state.verdict)"
	}

	// MARK: 메뉴 구성

	func menuNeedsUpdate(_ menu: NSMenu) {
		state = .read()
		menu.removeAllItems()

		addInfo(menu, "지금: \(state.verdict)")
		menu.addItem(.separator())

		let lid = NSMenuItem(title: "뚜껑 닫아도 안 잠들기",
		                     action: #selector(toggleLid), keyEquivalent: "")
		lid.target = self
		lid.state = state.lidPrevention ? .on : .off
		menu.addItem(lid)

		// caffeinate 하위 메뉴
		let cafItem = NSMenuItem(title: "caffeinate (작업 중 유휴 잠들기 방지)",
		                         action: nil, keyEquivalent: "")
		let cafMenu = NSMenu()
		for (mode, title) in [("on", "항상 허용 (macOS 기본)"),
		                      ("auto", "전원 연결 시만 허용"),
		                      ("off", "항상 차단")] {
			let item = NSMenuItem(title: title, action: #selector(setCaffeinate(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = mode
			item.state = (state.caffeinateMode == mode) ? .on : .off
			cafMenu.addItem(item)
		}
		if !state.shimInstalled {
			cafMenu.addItem(.separator())
			addInfo(cafMenu, "shim 미설치 — ~/.local/bin/caffeinate 필요")
		}
		cafItem.submenu = cafMenu
		menu.addItem(cafItem)

		menu.addItem(.separator())
		addInfo(menu, "화면 꺼짐   \(state.displaySleep)분")
		addInfo(menu, "전원        \(state.powerSource)\(state.batteryPercent.isEmpty ? "" : "  (\(state.batteryPercent))")")
		addInfo(menu, "caffeinate  \(state.caffeinateRunning)개 실행 중")

		menu.addItem(.separator())
		if !state.sudoersInstalled && FileManager.default.fileExists(atPath: sudoersSourcePath) {
			let item = NSMenuItem(title: "비밀번호 없이 토글하기 설정…",
			                      action: #selector(installSudoers), keyEquivalent: "")
			item.target = self
			menu.addItem(item)
		}
		let login = NSMenuItem(title: "로그인 시 자동 실행",
		                       action: #selector(toggleLoginItem), keyEquivalent: "")
		login.target = self
		login.state = LoginItem.isEnabled ? .on : .off
		menu.addItem(login)

		let quit = NSMenuItem(title: "PowerToggle 종료", action: #selector(quit), keyEquivalent: "q")
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

	// MARK: 동작

	@objc private func toggleLid() {
		let next = state.lidPrevention ? "0" : "1"
		if runElevated(["/usr/bin/pmset", "-a", "disablesleep", next]) {
			refresh()
		} else {
			alert("설정을 바꾸지 못했습니다",
			      "관리자 인증이 취소되었거나 실패했습니다. 터미널에서 다음을 실행해도 됩니다:\n\nsudo pmset -a disablesleep \(next)")
		}
	}

	@objc private func setCaffeinate(_ sender: NSMenuItem) {
		guard let mode = sender.representedObject as? String else { return }
		let dir = (caffeinateModePath as NSString).deletingLastPathComponent
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		do {
			try (mode + "\n").write(toFile: caffeinateModePath, atomically: true, encoding: .utf8)
		} catch {
			alert("모드를 저장하지 못했습니다", error.localizedDescription)
			return
		}
		if mode != "on" { shell("/usr/bin/pkill", ["-x", "caffeinate"]) }
		refresh()
	}

	@objc private func installSudoers() {
		let ok = runElevated(["/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "440",
		                      sudoersSourcePath, sudoersRulePath])
		if ok {
			alert("설정 완료", "이제 뚜껑 닫힘 방지 토글이 비밀번호 없이 바로 적용됩니다.\n\n되돌리려면: sudo rm \(sudoersRulePath)")
		} else {
			alert("설치하지 못했습니다", "관리자 인증이 취소되었거나 실패했습니다.")
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
		a.addButton(withTitle: "확인")
		NSApp.activate(ignoringOtherApps: true)
		a.runModal()
	}
}

// MARK: - 로그인 항목 (LaunchAgent)

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

// MARK: - 진입점

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

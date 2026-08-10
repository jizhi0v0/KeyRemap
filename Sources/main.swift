// KeyRemap — 按键盘选择的按键重映射工具（macOS）
//
// 起因：Magic Keyboard 的 9 键物理损坏，需要把另一个键映射成 9，且只能影响这块
// 键盘（同一块键盘会在 Mac mini 和 MacBook Pro 之间换用，不能碰 MBP 内置键盘）。
//
// 原理：映射通过 hidutil 的 UserKeyMapping 属性写在 IOHIDDevice 对象上，属于
// IOKit HID 层，在事件分发给应用之前生效 —— 所以密码框、登录窗口、锁屏、sudo
// 提示、终端、虚拟机内一律有效。（Accessibility API 方案在 secure input 下会被
// 系统屏蔽，这是它无法用于登录场景的根本原因。）
//
// 同一个二进制两种模式：
//   · 无参数     → SwiftUI 图形界面，选键盘、选映射、立即应用、装/卸开机项
//   · --daemon   → 无界面常驻，由 LaunchDaemon 以 root 运行，负责开机（含登录
//                  窗口）和设备重连后自动补上映射
//
// 为什么需要常驻：UserKeyMapping 挂在 IOHIDDevice 对象上，设备一断开就随对象
// 消失。蓝牙休眠、拔插线、重新配对之后都必须重设。

import SwiftUI
import IOKit
import IOKit.hid

// MARK: - 常量

let kAppLabel = "local.KeyRemap"
let kDaemonPath = "/usr/local/libexec/keyremapd"
let kPlistPath = "/Library/LaunchDaemons/local.KeyRemap.plist"
let kRulesDir = "/Library/Application Support/KeyRemap"
let kRulesPath = "/Library/Application Support/KeyRemap/rules.json"
let kHidutil = "/usr/bin/hidutil"

// HID 键码 = 0x700000000 + usage code（usage page 7 = 键盘）
func keyCode(_ usage: UInt32) -> UInt64 { 0x7_0000_0000 | UInt64(usage) }

// MARK: - 可选按键表

struct KeyDef: Identifiable, Hashable {
	let usage: UInt32
	let name: String
	var id: UInt32 { usage }
}

let allKeys: [KeyDef] = {
	var k: [KeyDef] = []
	// 修饰键放最前面，最常被当作替代键
	k += [
		KeyDef(usage: 0xE6, name: "右 Option"),
		KeyDef(usage: 0xE7, name: "右 Command"),
		KeyDef(usage: 0xE4, name: "右 Control"),
		KeyDef(usage: 0xE5, name: "右 Shift"),
		KeyDef(usage: 0x39, name: "Caps Lock"),
		KeyDef(usage: 0xE2, name: "左 Option"),
		KeyDef(usage: 0xE3, name: "左 Command"),
		KeyDef(usage: 0xE0, name: "左 Control"),
		KeyDef(usage: 0xE1, name: "左 Shift"),
	]
	// 数字
	let digits: [(UInt32, String)] = [
		(0x1E, "1"), (0x1F, "2"), (0x20, "3"), (0x21, "4"), (0x22, "5"),
		(0x23, "6"), (0x24, "7"), (0x25, "8"), (0x26, "9"), (0x27, "0"),
	]
	k += digits.map { KeyDef(usage: $0.0, name: "数字 \($0.1)") }
	// 字母
	for i in 0..<26 {
		let ch = String(UnicodeScalar(UInt8(65 + i)))
		k.append(KeyDef(usage: UInt32(0x04 + i), name: "字母 \(ch)"))
	}
	// 常用控制键与符号
	k += [
		KeyDef(usage: 0x28, name: "Return"),
		KeyDef(usage: 0x29, name: "Esc"),
		KeyDef(usage: 0x2A, name: "Delete（退格）"),
		KeyDef(usage: 0x2B, name: "Tab"),
		KeyDef(usage: 0x2C, name: "空格"),
		KeyDef(usage: 0x2D, name: "- 减号"),
		KeyDef(usage: 0x2E, name: "= 等号"),
		KeyDef(usage: 0x2F, name: "[ 左方括号"),
		KeyDef(usage: 0x30, name: "] 右方括号"),
		KeyDef(usage: 0x31, name: "\\ 反斜杠"),
		KeyDef(usage: 0x33, name: "; 分号"),
		KeyDef(usage: 0x34, name: "' 单引号"),
		KeyDef(usage: 0x35, name: "` 反引号"),
		KeyDef(usage: 0x36, name: ", 逗号"),
		KeyDef(usage: 0x37, name: ". 句点"),
		KeyDef(usage: 0x38, name: "/ 斜杠"),
		KeyDef(usage: 0x49, name: "Help / Insert"),
		KeyDef(usage: 0x4A, name: "Home"),
		KeyDef(usage: 0x4B, name: "Page Up"),
		KeyDef(usage: 0x4C, name: "Forward Delete"),
		KeyDef(usage: 0x4D, name: "End"),
		KeyDef(usage: 0x4E, name: "Page Down"),
		KeyDef(usage: 0x4F, name: "→ 右方向键"),
		KeyDef(usage: 0x50, name: "← 左方向键"),
		KeyDef(usage: 0x51, name: "↓ 下方向键"),
		KeyDef(usage: 0x52, name: "↑ 上方向键"),
	]
	// 功能键
	for i in 0..<12 {
		k.append(KeyDef(usage: UInt32(0x3A + i), name: "F\(i + 1)"))
	}
	// 小键盘
	let pad: [(UInt32, String)] = [
		(0x54, "小键盘 /"), (0x55, "小键盘 *"), (0x56, "小键盘 -"), (0x57, "小键盘 +"),
		(0x58, "小键盘 Enter"), (0x59, "小键盘 1"), (0x5A, "小键盘 2"), (0x5B, "小键盘 3"),
		(0x5C, "小键盘 4"), (0x5D, "小键盘 5"), (0x5E, "小键盘 6"), (0x5F, "小键盘 7"),
		(0x60, "小键盘 8"), (0x61, "小键盘 9"), (0x62, "小键盘 0"), (0x63, "小键盘 ."),
	]
	k += pad.map { KeyDef(usage: $0.0, name: $0.1) }
	return k
}()

func keyName(forUsage u: UInt32) -> String {
	allKeys.first { $0.usage == u }?.name ?? String(format: "usage 0x%02X", u)
}

// MARK: - 键盘设备

struct Keyboard: Identifiable, Hashable {
	var product: String
	var serial: String
	var vendorID: Int
	var productID: Int
	var transport: String
	var builtIn: Bool

	// 同一块键盘走 USB 和走蓝牙时是两个不同的 HID 设备（VendorID 不同，PID 相同），
	// 所以用 PID + 外接 作为身份，规则才能跟着键盘走而不是跟着连接方式走。
	var id: String { builtIn ? "builtin:\(vendorID):\(productID)" : "ext:\(productID)" }

	var transportLabel: String {
		switch transport.lowercased() {
		case "usb": return "USB"
		case "bluetooth", "bluetoothle": return "蓝牙"
		case "spi", "fifo", "spu": return "内置总线"
		default: return transport.isEmpty ? "未知" : transport
		}
	}

	/// hidutil --matching 用的匹配条件，逐条尝试，命中即写入。
	/// 每条都是 fail-closed：属性键写错或设备不在，hidutil 匹配不到任何设备并静默
	/// 跳过，绝不会退化成全局映射。
	var matchDicts: [[String: Any]] {
		let usage: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6]
		if builtIn {
			return [usage.merging(
				["Built-In": 1, "VendorID": vendorID, "ProductID": productID]) { a, _ in a }]
		}
		var out: [[String: Any]] = [
			// 主匹配：PID + 外接。跨 USB/蓝牙都命中同一块键盘，且因为
			// Built-In=0，永远不可能碰到 MacBook 内置键盘。
			usage.merging(["ProductID": productID, "Built-In": 0]) { a, _ in a }
		]
		if !serial.isEmpty {
			// 次匹配：序列号，最精确，作为兜底
			out.append(usage.merging(["SerialNumber": serial]) { a, _ in a })
		}
		return out
	}

	var matchSummary: String {
		builtIn
			? String(format: "内置键盘 · VID 0x%04X PID 0x%04X", vendorID, productID)
			: String(format: "匹配：PID 0x%04X + 外接%@", productID,
					 serial.isEmpty ? "" : " · 序列号 \(serial)")
	}
}

func jsonString(_ obj: Any) -> String {
	guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
		  let s = String(data: d, encoding: .utf8) else { return "{}" }
	return s
}

func enumerateKeyboards() -> [Keyboard] {
	// 只枚举，不 open —— IOHIDManagerOpen 会触发「输入监控」权限，这里完全不需要
	guard let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
			as IOHIDManager? else { return [] }
	IOHIDManagerSetDeviceMatching(mgr, [
		kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6,
	] as CFDictionary)
	guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }

	func str(_ d: IOHIDDevice, _ key: String) -> String {
		(IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? ""
	}
	func int(_ d: IOHIDDevice, _ key: String) -> Int {
		if let n = IOHIDDeviceGetProperty(d, key as CFString) as? Int { return n }
		return 0
	}
	func bool(_ d: IOHIDDevice, _ key: String) -> Bool {
		let v = IOHIDDeviceGetProperty(d, key as CFString)
		if let b = v as? Bool { return b }
		if let n = v as? Int { return n != 0 }
		return false
	}

	var seen = Set<String>()
	var out: [Keyboard] = []
	for d in set {
		let kb = Keyboard(
			product: str(d, kIOHIDProductKey),
			serial: str(d, kIOHIDSerialNumberKey),
			vendorID: int(d, kIOHIDVendorIDKey),
			productID: int(d, kIOHIDProductIDKey),
			transport: str(d, kIOHIDTransportKey),
			builtIn: bool(d, "Built-In"))
		if kb.product.isEmpty && kb.productID == 0 { continue }
		if seen.insert(kb.id).inserted { out.append(kb) }
	}
	return out.sorted { ($0.builtIn ? 1 : 0, $0.product) < ($1.builtIn ? 1 : 0, $1.product) }
}

// MARK: - 规则模型

struct Rule: Codable, Identifiable, Hashable {
	var deviceID: String
	var label: String
	var matches: [String]   // 已序列化的 hidutil --matching JSON
	var srcUsage: UInt32
	var dstUsage: UInt32
	var id: String { "\(deviceID)|\(srcUsage)" }   // 同一设备同一源键只能有一条

	var srcCode: UInt64 { keyCode(srcUsage) }
	var dstCode: UInt64 { keyCode(dstUsage) }
	var summary: String { "\(keyName(forUsage: srcUsage)) → \(keyName(forUsage: dstUsage))" }
}

struct RuleFile: Codable {
	var version = 1
	var rules: [Rule] = []
}

func loadRules(_ path: String) -> RuleFile {
	guard let d = FileManager.default.contents(atPath: path),
		  let f = try? JSONDecoder().decode(RuleFile.self, from: d) else { return RuleFile() }
	return f
}

// MARK: - 应用映射

@discardableResult
func runTool(_ path: String, _ args: [String]) -> (Int32, String) {
	let p = Process()
	p.executableURL = URL(fileURLWithPath: path)
	p.arguments = args
	let pipe = Pipe()
	p.standardOutput = pipe
	p.standardError = pipe
	do { try p.run() } catch { return (-1, "\(error)") }
	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	p.waitUntilExit()
	return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 把规则按设备分组写入。UserKeyMapping 是整个数组一次性覆盖的，所以同一设备的
/// 多条规则必须合并成一次 --set。
func apply(rules: [Rule], clearing extraDeviceMatches: [[String]] = []) {
	var byDevice: [String: [Rule]] = [:]
	for r in rules { byDevice[r.deviceID, default: []].append(r) }

	for (_, group) in byDevice {
		let mapping = group.map {
			["HIDKeyboardModifierMappingSrc": $0.srcCode, "HIDKeyboardModifierMappingDst": $0.dstCode]
		}
		let payload = jsonString(["UserKeyMapping": mapping])
		for m in group[0].matches {
			runTool(kHidutil, ["property", "--matching", m, "--set", payload])
		}
	}
	// 规则被删空的设备：显式清空，否则残留映射要等到设备重连才消失
	let empty = jsonString(["UserKeyMapping": []])
	for matches in extraDeviceMatches {
		for m in matches {
			runTool(kHidutil, ["property", "--matching", m, "--set", empty])
		}
	}
}

/// 该设备当前是否已带着我们写的映射（判断一条即可：数组是整体写入、整体消失的）
func isApplied(match: String, marker: UInt64) -> Bool {
	let (_, out) = runTool(kHidutil, ["property", "--matching", match, "--get", "UserKeyMapping"])
	return out.contains("\(marker)")
}

// MARK: - daemon 模式

/// 巡检一轮：凡是规则里的设备当前没带着我们的映射，就补上。
/// 必须是顶层函数 —— IOKit 的匹配回调是 C 函数指针，不能捕获上下文。
func daemonSweep() {
	let rules = loadRules(kRulesPath).rules
	guard !rules.isEmpty else { return }
	var byDevice: [String: [Rule]] = [:]
	for r in rules { byDevice[r.deviceID, default: []].append(r) }
	for (_, group) in byDevice {
		let mapping = group.map {
			["HIDKeyboardModifierMappingSrc": $0.srcCode,
			 "HIDKeyboardModifierMappingDst": $0.dstCode]
		}
		let payload = jsonString(["UserKeyMapping": mapping])
		for m in group[0].matches where !isApplied(match: m, marker: group[0].srcCode) {
			runTool(kHidutil, ["property", "--matching", m, "--set", payload])
		}
	}
}

func runDaemon() -> Never {
	let sweep = daemonSweep
	sweep()

	// IOKit 注册表通知：键盘一出现就立刻补映射（不用 IOHIDManagerOpen，所以不涉及
	// 「输入监控」权限）。通知之外再挂一个 3 秒巡检兜底，这样即使通知没触发（休眠
	// 唤醒、蓝牙重连等边界情况）也能自愈 —— 单次探测约 7ms，开销可忽略。
	let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
	if let notifyPort,
	   let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
		CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
		var iter: io_iterator_t = 0
		let matching = IOServiceMatching("IOHIDDevice")
		let cb: IOServiceMatchingCallback = { _, iterator in
			while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
			// 设备刚出现时属性可能还没就绪，稍等再写
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { daemonSweep() }
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { daemonSweep() }
		}
		IOServiceAddMatchingNotification(notifyPort, kIOMatchedNotification, matching, cb, nil, &iter)
		while case let obj = IOIteratorNext(iter), obj != 0 { IOObjectRelease(obj) }
	}

	let timer = DispatchSource.makeTimerSource(queue: .main)
	timer.schedule(deadline: .now() + 3, repeating: 3)
	timer.setEventHandler { sweep() }
	timer.resume()

	CFRunLoopRun()
	exit(0)
}

// MARK: - 开机项安装（需要管理员密码）

enum DaemonState { case notInstalled, installed(running: Bool) }

func daemonState() -> DaemonState {
	guard FileManager.default.fileExists(atPath: kPlistPath) else { return .notInstalled }
	let (code, out) = runTool("/bin/launchctl", ["print", "system/\(kAppLabel)"])
	return .installed(running: code == 0 && out.contains("state = running"))
}

/// 用一次管理员授权完成：拷 daemon 二进制、写规则文件、写 plist、重载。
/// 把命令写进临时脚本再整体提权执行，避免在 AppleScript 里做多层引号转义。
func installDaemon(rules: RuleFile) throws {
	let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
	let rulesTmp = tmp.appendingPathComponent("keyremap-rules.json")
	let plistTmp = tmp.appendingPathComponent("keyremap.plist")
	let shTmp = tmp.appendingPathComponent("keyremap-install.sh")

	let enc = JSONEncoder()
	enc.outputFormatting = [.prettyPrinted, .sortedKeys]
	try enc.encode(rules).write(to: rulesTmp)

	let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
	let plist = """
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>Label</key><string>\(kAppLabel)</string>
		<key>ProgramArguments</key>
		<array>
			<string>\(kDaemonPath)</string>
			<string>--daemon</string>
		</array>
		<key>RunAtLoad</key><true/>
		<key>KeepAlive</key><true/>
		<key>ProcessType</key><string>Background</string>
		<key>StandardErrorPath</key><string>/var/log/keyremap.log</string>
	</dict>
	</plist>
	"""
	try plist.write(to: plistTmp, atomically: true, encoding: .utf8)

	let sh = """
	#!/bin/sh
	set -e
	/usr/bin/install -d -o root -g wheel -m 755 /usr/local/libexec
	/usr/bin/install -d -o root -g wheel -m 755 "\(kRulesDir)"
	/usr/bin/install -o root -g wheel -m 755 "\(selfPath)" "\(kDaemonPath)"
	/usr/bin/install -o root -g wheel -m 644 "\(rulesTmp.path)" "\(kRulesPath)"
	/usr/bin/install -o root -g wheel -m 644 "\(plistTmp.path)" "\(kPlistPath)"
	/bin/launchctl bootout system/\(kAppLabel) 2>/dev/null || true
	/bin/launchctl bootstrap system "\(kPlistPath)"
	"""
	try sh.write(to: shTmp, atomically: true, encoding: .utf8)

	try runPrivileged("/bin/sh '\(shTmp.path)'")
}

func removeDaemon() throws {
	let sh = """
	#!/bin/sh
	/bin/launchctl bootout system/\(kAppLabel) 2>/dev/null || true
	/bin/rm -f "\(kPlistPath)" "\(kDaemonPath)" "\(kRulesPath)"
	/bin/rmdir "\(kRulesDir)" 2>/dev/null || true
	exit 0
	"""
	let shTmp = URL(fileURLWithPath: NSTemporaryDirectory())
		.appendingPathComponent("keyremap-remove.sh")
	try sh.write(to: shTmp, atomically: true, encoding: .utf8)
	try runPrivileged("/bin/sh '\(shTmp.path)'")
}

struct PrivError: LocalizedError {
	let msg: String
	var errorDescription: String? { msg }
}

func runPrivileged(_ command: String) throws {
	let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
		.replacingOccurrences(of: "\"", with: "\\\"")
	let script = "do shell script \"\(escaped)\" with administrator privileges"
	let (code, out) = runTool("/usr/bin/osascript", ["-e", script])
	if code != 0 {
		if out.contains("-128") { throw PrivError(msg: "已取消") }
		throw PrivError(msg: out.trimmingCharacters(in: .whitespacesAndNewlines))
	}
}

// MARK: - 界面

@MainActor
final class Model: ObservableObject {
	@Published var keyboards: [Keyboard] = []
	@Published var selected: Keyboard?
	@Published var rules: [Rule] = []
	@Published var srcUsage: UInt32 = 0xE6      // 默认右 Option
	@Published var dstUsage: UInt32 = 0x26      // 默认数字 9
	@Published var status = ""
	@Published var daemon: DaemonState = .notInstalled
	@Published var dirty = false                // 有未同步到开机项的改动

	private var timer: Timer?

	init() {
		rules = loadRules(kRulesPath).rules
		refresh()
		timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.refresh() }
		}
	}

	func refresh() {
		let list = enumerateKeyboards()
		if list.map(\.id) != keyboards.map(\.id) { keyboards = list }
		if selected == nil || !list.contains(where: { $0.id == selected?.id }) {
			selected = list.first { !$0.builtIn } ?? list.first
		}
		daemon = daemonState()
	}

	var rulesForSelected: [Rule] {
		guard let s = selected else { return [] }
		return rules.filter { $0.deviceID == s.id }
	}

	func addRule() {
		guard let kb = selected else { return }
		if srcUsage == dstUsage {
			status = "源键和目标键相同，没有意义"
			return
		}
		let r = Rule(deviceID: kb.id, label: kb.product.isEmpty ? kb.id : kb.product,
					 matches: kb.matchDicts.map { jsonString($0) },
					 srcUsage: srcUsage, dstUsage: dstUsage)
		rules.removeAll { $0.id == r.id }
		rules.append(r)
		dirty = true
		applyNow()
	}

	func delete(_ r: Rule) {
		rules.removeAll { $0.id == r.id }
		dirty = true
		// 该设备可能已无规则，需要显式清空，否则残留映射要等重连才消失
		let stillHas = rules.contains { $0.deviceID == r.deviceID }
		apply(rules: rules, clearing: stillHas ? [] : [r.matches])
		status = "已删除并生效"
	}

	/// 让设备的实际状态等于当前规则：有规则的写入，没规则的显式清空（否则残留映射
	/// 要等设备重连才消失）
	func applyNow() {
		let configured = Set(rules.map(\.deviceID))
		let clearing = keyboards
			.filter { !configured.contains($0.id) }
			.map { $0.matchDicts.map(jsonString) }
		apply(rules: rules, clearing: clearing)
		status = rules.isEmpty ? "已清空所有键盘的映射" : "已应用到当前连接的键盘"
	}

	func sync() {
		do {
			try installDaemon(rules: RuleFile(rules: rules))
			dirty = false
			status = "已保存，开机（含登录窗口）自动生效"
		} catch {
			status = "未保存：\(error.localizedDescription)"
		}
		refresh()
	}

	func remove() {
		do {
			try removeDaemon()
			status = "已移除开机项（当前映射仍在，重启后失效）"
		} catch {
			status = "未移除：\(error.localizedDescription)"
		}
		refresh()
	}
}

/// 键帽样式的按键标签 —— 比纯文字更容易一眼看出「哪个键变成哪个键」
struct KeyCap: View {
	let text: String
	var tinted = false

	var body: some View {
		Text(text)
			.font(.system(size: 12, weight: .medium, design: .rounded))
			.foregroundStyle(tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
			.padding(.horizontal, 10)
			.padding(.vertical, 5)
			.background {
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(tinted ? AnyShapeStyle(Color.accentColor.opacity(0.12))
								 : AnyShapeStyle(Material.regular))
			}
			.overlay {
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.strokeBorder(tinted ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12))
			}
			.shadow(color: .black.opacity(0.08), radius: 1, y: 1)
			.fixedSize()
	}
}

struct MappingPair: View {
	let src: UInt32
	let dst: UInt32

	var body: some View {
		HStack(spacing: 7) {
			KeyCap(text: keyName(forUsage: src))
			Image(systemName: "arrow.right")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(.tertiary)
			KeyCap(text: keyName(forUsage: dst), tinted: true)
		}
	}
}

struct Tag: View {
	let text: String
	var tint: Color = .secondary

	var body: some View {
		Text(text)
			.font(.system(size: 10, weight: .medium))
			.foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background {
				Capsule().fill(tint == .secondary
							   ? AnyShapeStyle(Color.primary.opacity(0.07))
							   : AnyShapeStyle(tint.opacity(0.15)))
			}
	}
}

struct KeyboardRow: View {
	let kb: Keyboard
	let selected: Bool
	let hasRules: Bool

	var body: some View {
		HStack(spacing: 11) {
			Image(systemName: selected ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 15))
				.foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))

			Image(systemName: kb.builtIn ? "laptopcomputer" : "keyboard")
				.font(.system(size: 15))
				.foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
				.frame(width: 20)

			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 5) {
					Text(kb.product.isEmpty ? "（无名称）" : kb.product)
						.fontWeight(selected ? .semibold : .regular)
					Tag(text: kb.transportLabel)
					if kb.builtIn { Tag(text: "内置", tint: .orange) }
					if hasRules { Tag(text: "已配置", tint: .green) }
				}
				Text(kb.matchSummary)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
			Spacer(minLength: 0)
		}
		.padding(.vertical, 3)
		.contentShape(Rectangle())
	}
}

struct ContentView: View {
	@StateObject var m = Model()

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			form
			Divider()
			footer
		}
		.frame(minWidth: 560, minHeight: 430)
		.background(.windowBackground)
	}

	// MARK: 顶部标题

	private var header: some View {
		HStack(spacing: 12) {
			RoundedRectangle(cornerRadius: 11, style: .continuous)
				.fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
									 startPoint: .top, endPoint: .bottom))
				.frame(width: 42, height: 42)
				.overlay {
					Image(systemName: "keyboard")
						.font(.system(size: 20, weight: .medium))
						.foregroundStyle(.white)
				}
				.shadow(color: .black.opacity(0.15), radius: 2, y: 1)

			VStack(alignment: .leading, spacing: 2) {
				Text("按键重映射").font(.system(size: 15, weight: .semibold))
				Text("按键盘分别设置，密码框与登录窗口同样有效")
					.font(.caption).foregroundStyle(.secondary)
			}
			Spacer()
		}
		.padding(.horizontal, 20)
		.padding(.top, 34)      // 让出无标题栏窗口的红绿灯按钮位置
		.padding(.bottom, 16)
	}

	// MARK: 主体

	private var form: some View {
		Form {
			Section {
				if m.keyboards.isEmpty {
					Label("没有检测到键盘", systemImage: "exclamationmark.triangle")
						.foregroundStyle(.secondary)
				}
				ForEach(m.keyboards) { kb in
					KeyboardRow(kb: kb,
								selected: m.selected?.id == kb.id,
								hasRules: m.rules.contains { $0.deviceID == kb.id })
						.onTapGesture { m.selected = kb }
				}
			} header: {
				Text("键盘")
			} footer: {
				Text("规则只作用于选中的这块键盘，跨 USB 与蓝牙都跟着它走；MacBook 内置键盘不会受影响。")
					.font(.caption2).foregroundStyle(.tertiary)
			}

			Section("新建映射") {
				Picker("把这个键", selection: $m.srcUsage) {
					ForEach(allKeys) { Text($0.name).tag($0.usage) }
				}
				Picker("变成", selection: $m.dstUsage) {
					ForEach(allKeys) { Text($0.name).tag($0.usage) }
				}
				HStack {
					MappingPair(src: m.srcUsage, dst: m.dstUsage)
					Spacer()
					Button("添加规则") { m.addRule() }
						.buttonStyle(.borderedProminent)
						.disabled(m.selected == nil || m.srcUsage == m.dstUsage)
				}
			}

			if !m.rules.isEmpty {
				Section("已有规则") {
					ForEach(m.rules) { r in
						HStack(spacing: 10) {
							MappingPair(src: r.srcUsage, dst: r.dstUsage)
							Spacer(minLength: 8)
							Text(r.label)
								.font(.caption2)
								.foregroundStyle(.tertiary)
								.lineLimit(1)
								.truncationMode(.middle)
							Button {
								m.delete(r)
							} label: {
								Image(systemName: "minus.circle.fill")
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
							.help("删除这条规则")
						}
						.padding(.vertical, 2)
					}
				}
			}
		}
		.formStyle(.grouped)
	}

	// MARK: 底部状态与操作

	private var footer: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 7) {
				switch m.daemon {
				case .notInstalled:
					Image(systemName: "circle.dotted").foregroundStyle(.secondary)
					Text("开机项未安装 —— 当前映射重启后会失效")
				case .installed(let running):
					Image(systemName: running ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
						.foregroundStyle(running ? .green : .orange)
					Text(running ? "开机项运行中，登录窗口同样有效" : "开机项已安装但未运行")
				}
				if m.dirty {
					Tag(text: "有未保存改动", tint: .orange)
				}
				Spacer()
			}
			.font(.caption)

			HStack(spacing: 8) {
				if !m.status.isEmpty {
					Text(m.status)
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(2)
				}
				Spacer(minLength: 12)
				if case .installed = m.daemon {
					Button("移除开机项") { m.remove() }
						.controlSize(.regular)
				}
				Button("立即应用") { m.applyNow() }
				Button("保存并开机生效") { m.sync() }
					.buttonStyle(.borderedProminent)
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 14)
		.background(.bar)
	}
}

struct KeyRemapApp: App {
	var body: some Scene {
		WindowGroup("按键重映射") {
			ContentView()
		}
		.windowStyle(.hiddenTitleBar)
		.windowResizability(.contentMinSize)
		.defaultSize(width: 560, height: 520)
	}
}

// MARK: - 入口

if CommandLine.arguments.contains("--daemon") {
	runDaemon()
} else if CommandLine.arguments.contains("--list") {
	// 排查用：打印检测到的键盘、生成的匹配条件、以及各条匹配当前命中的设备
	for kb in enumerateKeyboards() {
		print("\(kb.product.isEmpty ? "（无名称）" : kb.product)  [\(kb.transportLabel)]"
			  + (kb.builtIn ? " [内置]" : ""))
		print(String(format: "  VID 0x%04X  PID 0x%04X  序列号 %@",
					 kb.vendorID, kb.productID, kb.serial.isEmpty ? "（无）" : kb.serial))
		print("  设备身份 \(kb.id)")
		for m in kb.matchDicts {
			let s = jsonString(m)
			let (_, out) = runTool(kHidutil, ["property", "--matching", s, "--get", "UserKeyMapping"])
			let hit = out.contains("RegistryID") ? "命中" : "无匹配"
			print("  匹配 \(hit)  \(s)")
		}
	}
	let rules = loadRules(kRulesPath).rules
	print("\n开机规则文件 \(kRulesPath)：\(rules.isEmpty ? "无规则或不存在" : "")")
	for r in rules { print("  \(r.label): \(r.summary)  → \(r.matches.count) 条匹配") }
	exit(0)
} else {
	KeyRemapApp.main()
}

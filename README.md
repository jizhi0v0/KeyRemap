# KeyRemap

**按指定键盘重映射按键的 macOS 小工具。** 映射写在 IOKit HID 层，所以在密码框、锁屏、登录窗口、`sudo` 提示、终端里一律有效；而且只作用于你选定的那一块键盘 —— MacBook 内置键盘不受影响。

> A tiny macOS utility that remaps keys **per keyboard**. Mappings are applied at the IOKit HID layer via `hidutil`, so they work in password fields, the lock screen and the login window — and only on the physical keyboard you pick, leaving the built-in MacBook keyboard untouched. No kernel extension, no Accessibility permission, no Input Monitoring permission. Single Swift file, ~1.3 MB universal app.

起因很具体：一块 Magic Keyboard 的 `9` 键物理损坏，需要把右 Option 变成 `9`；后来坏键还开始在按旁边的键时自己狂打 `9`，于是又加了「屏蔽」—— 把坏键本身吞掉。这块键盘会在 Mac mini 和 MacBook Pro 之间换用，所以映射必须**跟着键盘走**，且**绝不能碰 MacBook 的内置键盘**。

## 为什么不是 AppleScript / 事件监听那一套

最容易想到的办法是模拟按键：

```sh
osascript -e 'tell application "System Events" to keystroke "9"'
```

它在登录窗口里**一定会失效**：登录窗口不属于任何用户会话，`System Events` 这类需要投递到会话里的手段在那里没有目标可用。密码框里也靠不住 —— 启用 Secure Keyboard Entry 之后，系统会切断键盘事件流向「拦截进程」（[TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) 点名了事件 tap 和抢占 HID 设备两类）。

（准确说，TN2150 描述的是阻止**拦截**；注入是否一并被阻止，Apple 没有明说，本项目也没有实测过。但无论如何它覆盖不了登录窗口。）

`hidutil` 的 `UserKeyMapping` 走的是另一条路：映射写在 `IOHIDDevice` 对象上，事件在被分发给任何应用**之前**就已经变成了另一个键。所以它产生的是一个真正的按键，Secure Input 拦不住。副作用也很自然 —— 右 Option 变成 `9` 之后，Shift 组合出 `(`，Cmd 组合就是 `Cmd-9`。

## 怎么做到「只认某一块键盘」

`hidutil property --matching` 接受一个 IOHIDDevice 属性字典。关键在于选对属性：

同一块键盘走 USB 和走蓝牙时，在 HID 层是**两个不同的设备** —— VendorID 分别是 `0x05AC` 和 `0x004C`，但 **ProductID 相同**。所以主匹配条件是：

```json
{"ProductID": 666, "Built-In": 0, "PrimaryUsagePage": 1, "PrimaryUsage": 6}
```

- 按 `ProductID` 匹配 → 规则跨 USB / 蓝牙都跟着同一块键盘走。
- `Built-In: 0` → 永远不可能命中 MacBook 内置键盘。

注意属性键名是**带连字符的 `Built-In`**（`kIOHIDBuiltInKey`）。写成 `BuiltIn` 匹配不到任何设备 —— 好在这是 fail-closed 的：未知属性键匹配不到东西，只会静默跳过，绝不会退化成全局映射。

程序还会附带一条按 `SerialNumber` 的匹配作为兜底。`--list` 可以看到实际命中情况：

```
$ KeyRemap.app/Contents/MacOS/KeyRemap --list
Magic Keyboard with Touch ID  [USB]
  VID 0x05AC  PID 0x029A  序列号 XXXXXXXXXXXXX
  设备身份 ext:666
  匹配 命中  {"Built-In":0,"PrimaryUsage":6,"PrimaryUsagePage":1,"ProductID":666}
  匹配 命中  {"PrimaryUsage":6,"PrimaryUsagePage":1,"SerialNumber":"XXXXXXXXXXXXX"}
```

上面的序列号是抹过的。`--list` 打印的是真实序列号 —— 蓝牙连接时 macOS 上报的是这块键盘的 BT MAC 地址，贴到 issue 或截图之前记得抹掉。

## 为什么需要一个常驻进程

`UserKeyMapping` 是挂在 `IOHIDDevice` 对象上的属性，**设备一断开就随对象消失**：拔插 USB 线、蓝牙键盘休眠、重新配对、重启，映射都会没了。

所以「开机自动生效」会安装一个 LaunchDaemon（`local.KeyRemap`，system 域，root，`RunAtLoad`）：

- 开机时在 loginwindow 接受输入之前就把映射写好 → **登录窗口有效**。
- 用 IOKit 注册表通知（`IOServiceAddMatchingNotification`）监听设备出现，键盘一插上/一连上就补映射；外加 3 秒巡检兜底，覆盖休眠唤醒之类的边界情况。单次探测约 7 ms，常驻 0% CPU / 11 MB。
- 特意**没有**用 `IOHIDManagerOpen` —— 那会触发「输入监控」权限申请。这个工具不需要读取任何按键，也不该长得像键盘记录器。

顺带一个容易搞错的点：**注销不会重建设备对象**，所以映射会原封不动留到登录窗口。想验证 daemon 是否真的在工作，得**重启**，或者拔插一次键盘。

## 安装

### 方式一：下载 Release

从 [Releases](https://github.com/jizhi0v0/KeyRemap/releases) 下载 zip，解压，拖到 `/Applications`，双击打开。已签名并公证，不需要解隔离属性。

### 方式二：从源码构建

需要 Xcode 命令行工具。`build.sh` 会自动挑签名方式：本机有 Developer ID Application 证书就用它（并启用 hardened runtime + 安全时间戳），否则退回 ad-hoc 签名。

```sh
git clone https://github.com/jizhi0v0/KeyRemap.git && cd KeyRemap && sh build.sh
```

产物在 `build/KeyRemap.app`。

## 用法

1. 打开 App，在「键盘」里点选目标键盘。
2. 选「把 [某个键] 变成 [某个键]」，点**添加规则** —— 立即生效，不需要密码。
   - 目标选「无（屏蔽）」就是把这个键吞掉（映射到 HID usage `0x00`）。坏键自己乱触发时用它；和「右 Option → 9」这类规则互不干扰，`hidutil` 只替换一次、不会连锁。
3. 点**开机自动生效** —— 输一次管理员密码，安装 LaunchDaemon，之后开机与设备重连都自动生效。

**卸载**：App 里点「移除开机项」。或者手工：

```sh
sudo launchctl bootout system/local.KeyRemap
sudo rm -f /Library/LaunchDaemons/local.KeyRemap.plist
sudo rm -rf "/Library/Application Support/KeyRemap"
sudo rm -f /var/log/keyremap.log
hidutil property --set '{"UserKeyMapping":[]}'
```

## 已知限制

- **FileVault 开机解锁界面无效。** 那一步数据卷还没解锁，而 daemon、它的 plist、规则文件全都在数据卷上（`/Library/...`），launchd 那时候根本看不到它们 —— 装在同样位置的工具都一样，Karabiner 也不例外。如果开机密码里含有坏掉的那个键，只能改密码、或者开机时临时接另一块键盘。（`man fdesetup` 的 REMOTE UNLOCKING VIA SSH 一节还记载了一条远程解锁的路子，本项目未实测。）
- **屏蔽只能拦住键盘真正报成 `9` 的事件。** 如果坏键导致的是矩阵短路 —— 按旁边的键时硬件只报 `9`、本键反而丢了 —— 那是硬件层面的错，软件救不回来。
- **只能单键换单键。** `hidutil` 的模型就是这样，做不了组合键触发（`右Cmd-O → 9`）、长按、连击、按应用区分。要这些请用 Karabiner-Elements。
- `fn` / 地球键不在可选列表里（它不在标准键盘 usage page 上）。
- 蓝牙键盘在登录窗口需要先重新连上，映射会在它出现后的一瞬间补上，极端情况可能有一两秒延迟。USB 无此问题。

## 和现有项目的关系

这不是一个填补空白的项目 —— 先看看这些够不够你用：

| | GUI | 指定键盘 | 开机持久 | 重连自愈 | 组合键 |
|---|---|---|---|---|---|
| **KeyRemap**（本项目） | ✓ | ✓ | ✓ | ✓ | ✗ |
| [Karabiner-Elements](https://karabiner-elements.pqrs.org/) | ✓ | ✓ Devices 标签页 | ✓ | ✓ | ✓ |
| [PearHID](https://github.com/alienator88/PearHID) | ✓ | ✗ 全局 | ✓ | ? | ✗ |
| [kb-remap](https://github.com/rossmacarthur/kb-remap) | ✗ CLI | ✓ `--name` | ✗ | ✗ | ✗ |

**功能最全的是 Karabiner-Elements**，而且它同样支持登录窗口（Misc 标签页把配置复制为 system default configuration）。如果你需要组合键、按应用规则，直接用它。

本项目的位置：只做一件事，因此**不装内核扩展 / 系统扩展，不申请任何权限**，一个 Swift 文件、约 1.3 MB（universal）。hidutil 这一层的现有工具里，PearHID 有 GUI 但只能全局映射，kb-remap 能指定设备但明确不做持久化 —— 「按设备 + 开机持久 + 重连自愈 + GUI」这四件事凑齐的，暂时没找到。

## 结构

```
Sources/main.swift    全部代码：GUI（SwiftUI）、--daemon 常驻模式、--list 排查模式
Tools/makeicon.swift  生成 App 图标（渐变圆角方块 + 键盘符号）
build.sh              编译 + 打图标 + 组 bundle + 签名
Tests/run.sh          集成测试
```

## 测试

```sh
sh Tests/run.sh
```

不需要 root，也不会改动真实键盘的映射（用一个不存在的 PID 作为规则目标）。包含：

- 构建产物检查：universal slice、每个 slice 的 `minos` 与 `Info.plist` 一致、签名有效
- `bundle 副本签名有效` vs `单独拷可执行文件签名失效` —— daemon 安装方式的回归测试
- 用户域 LaunchAgent 拉起 daemon，断言 `state = running` 且 10 秒后仍在运行
- `KeyRemap --selftest`：键码换算（含屏蔽目标 `0x700000000`）、匹配条件生成（含 `Built-In` 连字符和 fail-closed）、
  设备身份跨 USB/蓝牙一致、多规则合并载荷、规则文件 round-trip、空规则的保存与清空语义

同一个二进制四种模式：无参数是 GUI，`--daemon` 由 LaunchDaemon 以 root 运行，`--list` 打印检测到的键盘与匹配命中情况，`--selftest` 跑纯逻辑断言。

## License

MIT

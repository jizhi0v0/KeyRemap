// 生成 KeyRemap.app 的图标：渐变圆角方块 + 键盘符号，输出 iconset 供 iconutil 打包
import AppKit

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
	guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
									 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
									 isPlanar: false, colorSpaceName: .deviceRGB,
									 bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
	guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = ctx

	let size = CGFloat(px)
	// macOS 图标惯例：内容占画布约 82%，四周留白
	let inset = size * 0.09
	let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
	let radius = rect.width * 0.2237   // Apple 的 squircle 圆角比例

	let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
	let gradient = NSGradient(colors: [
		NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
		NSColor(srgbRed: 0.48, green: 0.29, blue: 0.85, alpha: 1),
	])
	gradient?.draw(in: path, angle: -90)

	// 顶部高光，让方块不显得平
	NSGraphicsContext.current?.saveGraphicsState()
	path.addClip()
	let sheen = NSGradient(colors: [
		NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0),
	])
	sheen?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
				angle: -90)
	NSGraphicsContext.current?.restoreGraphicsState()

	// 键盘符号
	let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
	if let sym = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
		.withSymbolConfiguration(cfg) {
		let tinted = NSImage(size: sym.size, flipped: false) { r in
			NSColor.white.set()
			sym.draw(in: r)
			r.fill(using: .sourceAtop)
			return true
		}
		let w = size * 0.5
		let h = w * (sym.size.height / sym.size.width)
		tinted.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2 - size * 0.01,
							   width: w, height: h))
	}

	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])
}

// iconutil 需要的全套尺寸
let specs: [(String, Int)] = [
	("icon_16x16", 16), ("icon_16x16@2x", 32),
	("icon_32x32", 32), ("icon_32x32@2x", 64),
	("icon_128x128", 128), ("icon_128x128@2x", 256),
	("icon_256x256", 256), ("icon_256x256@2x", 512),
	("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
	guard let data = render(px) else { print("失败 \(name)"); continue }
	try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("已生成 \(specs.count) 个尺寸")

// App 图标生成脚本（无第三方依赖，直接用 CoreGraphics 绘制）。
// 用法：swift Tools/GenerateAppIcon.swift zhz-app/Assets.xcassets/AppIcon.appiconset
// 会覆盖生成 icon_16/32/64/128/256/512/1024.png。

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let base: CGFloat = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// 圆角矩形底板 + 渐变 + 内高光
func drawPlate(_ ctx: CGContext) {
    let side: CGFloat = 824
    let rect = CGRect(x: (base - side) / 2, y: (base - side) / 2, width: side, height: side)
    let path = CGPath(roundedRect: rect, cornerWidth: 184, cornerHeight: 184, transform: nil)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: rgb(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x0B111F))
    ctx.fillPath()
    ctx.restoreGState()

    // 底板渐变
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: space,
        colors: [rgb(0x1E2E52), rgb(0x121B30), rgb(0x080C16)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: 0, y: rect.minY),
        options: []
    )
    // 左上柔光
    let glow = CGGradient(
        colorsSpace: space,
        colors: [rgb(0x3B82F6, 0.28), rgb(0x3B82F6, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: rect.minX + 190, y: rect.maxY - 130), startRadius: 0,
        endCenter: CGPoint(x: rect.minX + 190, y: rect.maxY - 130), endRadius: 560,
        options: []
    )
    ctx.restoreGState()

    // 内高光描边
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(5)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.strokePath()
    ctx.restoreGState()
}

/// 用渐变填充一条被描边转成实心形状的路径
func strokeGradient(
    _ ctx: CGContext,
    path: CGPath,
    width: CGFloat,
    cap: CGLineCap,
    join: CGLineJoin,
    colors: [CGColor],
    from: CGPoint,
    to: CGPoint
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.setLineJoin(join)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// CPU 占用环 + 网速折线
func drawSymbol(_ ctx: CGContext, simplified: Bool) {
    let c = CGPoint(x: base / 2, y: base / 2)
    let radius: CGFloat = simplified ? 232 : 236
    let ringWidth: CGFloat = simplified ? 86 : 74

    // 环形轨道（底色）：缺口 90° 朝下，仪表式
    let start = -CGFloat.pi * 0.75
    let sweep = CGFloat.pi * 1.5
    let track = CGMutablePath()
    track.addArc(center: c, radius: radius, startAngle: start, endAngle: start - sweep,
                 clockwise: true)
    ctx.saveGState()
    ctx.addPath(track)
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.strokePath()
    ctx.restoreGState()

    // 环形进度（约 72%，自左下起沿左侧向上）
    let progress = CGMutablePath()
    progress.addArc(center: c, radius: radius, startAngle: start,
                    endAngle: start - sweep * 0.72, clockwise: true)
    strokeGradient(
        ctx, path: progress, width: ringWidth, cap: .round, join: .round,
        colors: [rgb(0x22D3EE), rgb(0x3B82F6), rgb(0x818CF8)],
        from: CGPoint(x: c.x - radius, y: c.y - radius),
        to: CGPoint(x: c.x + radius, y: c.y + radius)
    )

    // 网速折线
    let line = CGMutablePath()
    let pts: [CGPoint] = simplified
        ? [CGPoint(x: -96, y: -30), CGPoint(x: -4, y: 44), CGPoint(x: 96, y: -44)]
        : [CGPoint(x: -122, y: -18), CGPoint(x: -52, y: 52), CGPoint(x: 12, y: -58),
           CGPoint(x: 72, y: 26), CGPoint(x: 126, y: -34)]
    let abs = pts.map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) }
    line.move(to: abs[0])
    for p in abs.dropFirst() { line.addLine(to: p) }

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: rgb(0x22D3EE, 0.55))
    ctx.addPath(line)
    ctx.setLineWidth(simplified ? 54 : 46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0xF8FAFF))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    let s = CGFloat(size) / base
    ctx.scaleBy(x: s, y: s)
    drawPlate(ctx)
    drawSymbol(ctx, simplified: size <= 32)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(render(size: size), to: "\(outDir)/icon_\(size).png")
}
print("done")

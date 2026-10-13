import AppKit

// Generates the three adaptive 1024 app-icon variants (light / dark / tinted)
// into Assets.xcassets/AppIcon.appiconset. Run:  swift design/GenerateIcons.swift
// Art is flat & full-bleed; iOS 26 applies the Liquid Glass treatment itself.

enum Style { case light, dark, tinted }

func draw(_ style: Style, to path: String) {
    let S = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    let sz = CGFloat(S)
    let cs = CGColorSpaceCreateDeviceRGB()

    // background
    switch style {
    case .light:
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.431, green: 0.608, blue: 0.847, alpha: 1),   // blue
            CGColor(red: 0.498, green: 0.769, blue: 0.639, alpha: 1)] as CFArray, // green
            locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: 0, y: sz), end: CGPoint(x: sz, y: 0), options: [])
    case .dark:
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.071, green: 0.094, blue: 0.125, alpha: 1),
            CGColor(red: 0.063, green: 0.110, blue: 0.090, alpha: 1)] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: 0, y: sz), end: CGPoint(x: sz, y: 0), options: [])
    case .tinted:
        g.clear(CGRect(x: 0, y: 0, width: sz, height: sz))   // transparent; system applies tint
    }

    // glyph: the Nidhi kalasha (treasure pot) — geometry matches design/logos/kalasha/mark.svg.
    // SVG space is y-down; the transform flips it into CG's y-up and centres the art.
    let zenAccent = CGColor(red: 0.431, green: 0.608, blue: 0.847, alpha: 1)  // #6E9BD8
    let zenDeep   = CGColor(red: 0.310, green: 0.498, blue: 0.769, alpha: 1)  // #4F7FC4
    let sage      = CGColor(red: 0.498, green: 0.769, blue: 0.639, alpha: 1)  // #7FC4A3
    let sageDeep  = CGColor(red: 0.357, green: 0.647, blue: 0.522, alpha: 1)  // #5BA585

    let pot = CGMutablePath()
    pot.move(to: CGPoint(x: 90, y: 62))
    pot.addQuadCurve(to: CGPoint(x: 92, y: 50), control: CGPoint(x: 84, y: 54))
    pot.addLine(to: CGPoint(x: 168, y: 50))
    pot.addQuadCurve(to: CGPoint(x: 170, y: 62), control: CGPoint(x: 176, y: 54))
    pot.addQuadCurve(to: CGPoint(x: 196, y: 112), control: CGPoint(x: 196, y: 78))
    pot.addQuadCurve(to: CGPoint(x: 130, y: 152), control: CGPoint(x: 196, y: 152))
    pot.addQuadCurve(to: CGPoint(x: 64, y: 112), control: CGPoint(x: 64, y: 152))
    pot.addQuadCurve(to: CGPoint(x: 90, y: 62), control: CGPoint(x: 64, y: 78))
    pot.closeSubpath()
    let coins: [(CGFloat, CGFloat, Bool)] = [(112, 34, false), (130, 26, true), (148, 34, false)]
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: 88, y: 96))
    smile.addQuadCurve(to: CGPoint(x: 172, y: 96), control: CGPoint(x: 130, y: 116))

    g.saveGState()
    g.translateBy(x: 70, y: 801)
    g.scaleBy(x: 3.4, y: -3.4)

    switch style {
    case .light:                                     // white pot + coins, deep-blue smile
        g.setFillColor(.white)
        g.addPath(pot); g.fillPath()
        for (x, y, _) in coins { g.fillEllipse(in: CGRect(x: x - 8, y: y - 8, width: 16, height: 16)) }
        g.setStrokeColor(zenDeep.copy(alpha: 0.8)!)
    case .dark:                                      // zen-gradient pot, sage coins, white smile
        g.saveGState()
        g.addPath(pot); g.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [zenAccent, zenDeep] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: 64, y: 50), end: CGPoint(x: 196, y: 152), options: [])
        g.restoreGState()
        for (x, y, deep) in coins {
            g.setFillColor(deep ? sageDeep : sage)
            g.fillEllipse(in: CGRect(x: x - 8, y: y - 8, width: 16, height: 16))
        }
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.7))
    case .tinted:                                    // monochrome; smile punched transparent
        let mono = CGColor(gray: 0.92, alpha: 1)
        g.setFillColor(mono)
        g.addPath(pot); g.fillPath()
        for (x, y, _) in coins { g.fillEllipse(in: CGRect(x: x - 8, y: y - 8, width: 16, height: 16)) }
        g.setBlendMode(.clear)
        g.setStrokeColor(CGColor(gray: 0, alpha: 1))
    }
    g.setLineWidth(5); g.setLineCap(.round)
    g.addPath(smile); g.strokePath()
    g.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let base = "/Users/suhailaka/Nidhi/Nidhi/Assets.xcassets/AppIcon.appiconset"
draw(.light,  to: "\(base)/icon-light-1024.png")
draw(.dark,   to: "\(base)/icon-dark-1024.png")
draw(.tinted, to: "\(base)/icon-tinted-1024.png")

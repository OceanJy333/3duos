// Input: a selected fixed skin and the available drawing rectangle.
// Output: image, screen and touch frames transformed together.
// Pos: fixed-profile console rendering; screen pixels keep native LCD proportions.
import Foundation
import CoreGraphics

struct ConsoleShellGeometry {
    let profile: ConsoleSkinProfile
    let area: CGRect

    init(profile: ConsoleSkinProfile, in viewport: CGRect) {
        self.profile = profile
        let sx = viewport.width / profile.size.width, sy = viewport.height / profile.size.height
        let scale = profile.asset == ConsoleSkinProfile.duo.asset ? max(sx, sy) : min(sx, sy)
        let size = CGSize(width: profile.size.width * scale, height: profile.size.height * scale)
        area = CGRect(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func map(_ rect: CGRect) -> CGRect {
        let scale = area.width / profile.size.width
        return CGRect(x: area.minX + rect.minX * scale, y: area.minY + rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }
    private func lcd(_ slot: CGRect, ratio: CGFloat) -> CGRect {
        let rect = map(slot)
        let width = min(rect.width, rect.height * ratio)
        let height = width / ratio
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    var topAperture: CGRect { map(profile.top) }
    var bottomAperture: CGRect { map(profile.bottom) }
    var topScreen: CGRect { lcd(profile.top, ratio: 5.0 / 3) }
    var bottomScreen: CGRect {
        profile.asset == ConsoleSkinProfile.duo.asset ? bottomAperture : lcd(profile.bottom, ratio: 4.0 / 3)
    }
    var circlePad: CGRect { map(profile.pad) }
    var circlePadTouch: CGRect {
        profile.asset == ConsoleSkinProfile.duo.asset
            ? map(CGRect(x: 28, y: 815, width: 186, height: 270)) : circlePad.insetBy(dx: -8, dy: -12)
    }
    var cStick: CGRect { map(profile.cStick) }
    var dpad: [CGRect] {
        if profile.asset == ConsoleSkinProfile.duo.asset {
            return [CGRect(x: 85, y: 1083, width: 48, height: 44),
                    CGRect(x: 44, y: 1127, width: 42, height: 50),
                    CGRect(x: 132, y: 1127, width: 43, height: 50),
                    CGRect(x: 85, y: 1177, width: 48, height: 47)].map(map)
        }
        let r = profile.cross, w = r.width / 3, h = r.height / 3
        return [CGRect(x: r.minX + w, y: r.minY, width: w, height: h),
                CGRect(x: r.minX, y: r.minY + h, width: w, height: h),
                CGRect(x: r.minX + 2 * w, y: r.minY + h, width: w, height: h),
                CGRect(x: r.minX + w, y: r.minY + 2 * h, width: w, height: h)].map(map)
    }
    var faceButtons: [CGRect] { profile.faces.map(map) }
    var shoulders: [CGRect] {
        [CGRect(x: 0, y: profile.hingeY, width: 100, height: 54),
         CGRect(x: profile.size.width - 100, y: profile.hingeY, width: 100, height: 54),
         CGRect(x: 100, y: profile.hingeY, width: 100, height: 54),
         CGRect(x: profile.size.width - 200, y: profile.hingeY, width: 100, height: 54)].map(map)
    }
    var select: CGRect { map(profile.footer[0]) }
    var menu: CGRect { map(profile.footer[1]) }
    var start: CGRect { map(profile.footer[2]) }
}

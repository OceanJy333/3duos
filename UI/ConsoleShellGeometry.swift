// Input: available viewport and measured coordinates on the all-white XL bitmap.
// Output: panel, screen and control frames using one shared coordinate mapping.
// Pos: adaptive console layout, independent of UIKit and the emulator core.
import Foundation
import CoreGraphics

struct ConsoleShellGeometry {
    static let imageSize = CGSize(width: 1052, height: 1495)
    static let splitY: CGFloat = 709
    let upperPanel: CGRect
    let lowerPanel: CGRect

    init(in viewport: CGRect, spread: Bool) {
        func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
            let scale = min(rect.width / size.width, rect.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                          width: fitted.width, height: fitted.height)
        }
        if spread {
            let gap: CGFloat = viewport.width >= 900 ? 24 : 12
            let width = (viewport.width - gap) / 2
            upperPanel = fit(CGSize(width: Self.imageSize.width, height: Self.splitY),
                             in: CGRect(x: viewport.minX, y: viewport.minY, width: width, height: viewport.height))
            lowerPanel = fit(CGSize(width: Self.imageSize.width, height: Self.imageSize.height - Self.splitY),
                             in: CGRect(x: viewport.minX + width + gap, y: viewport.minY, width: width, height: viewport.height))
        } else {
            let area = fit(Self.imageSize, in: viewport)
            let height = area.height * Self.splitY / Self.imageSize.height
            upperPanel = CGRect(x: area.minX, y: area.minY, width: area.width, height: height)
            lowerPanel = CGRect(x: area.minX, y: area.minY + height, width: area.width, height: area.height - height)
        }
    }

    private func imageRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        let lower = y >= Self.splitY
        let panel = lower ? lowerPanel : upperPanel
        let scale = panel.width / Self.imageSize.width
        return CGRect(x: panel.minX + x * scale, y: panel.minY + (y - (lower ? Self.splitY : 0)) * scale,
                      width: width * scale, height: height * scale)
    }

    var topScreen: CGRect { imageRect(75, 96, 900, 540) }
    // Keep the 320:240 LCD undistorted inside the taller skin aperture.
    var bottomScreen: CGRect { imageRect(215, 847.5, 620, 465) }
    var circlePad: CGRect { imageRect(28, 878, 164, 174) }
    var circlePadTouch: CGRect { imageRect(28, 815, 186, 270) }
    var cStick: CGRect { imageRect(877, 852, 73, 74) }
    var dpad: [CGRect] { [imageRect(85, 1083, 48, 44), imageRect(44, 1127, 42, 50),
                         imageRect(132, 1127, 43, 50), imageRect(85, 1177, 48, 47)] }
    var faceButtons: [CGRect] { [imageRect(913, 938, 63, 64), imageRect(858, 998, 63, 63),
                                imageRect(967, 998, 63, 63), imageRect(913, 1058, 63, 64)] }
    var shoulders: [CGRect] { [imageRect(0, 750, 100, 54), imageRect(951, 750, 100, 54),
                              imageRect(100, 750, 100, 54), imageRect(851, 750, 100, 54)] }
    var select: CGRect { imageRect(252, 1359, 164, 57) }
    var menu: CGRect { imageRect(463, 1359, 124, 57) }
    var start: CGRect { imageRect(634, 1359, 163, 57) }
}

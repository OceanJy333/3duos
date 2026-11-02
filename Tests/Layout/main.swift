// Input: phone, tablet and narrow-window viewport sizes.
// Output: assertions for visible controls, panel alignment and native LCD proportions.
// Pos: standalone geometry regression check, also run before release packaging.
import Foundation
import CoreGraphics

var checks = 0
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    checks += 1
}
let sizes: [CGSize] = [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                       CGSize(width: 393, height: 852), CGSize(width: 430, height: 932),
                       CGSize(width: 768, height: 1024), CGSize(width: 834, height: 1194),
                       CGSize(width: 1024, height: 1366), CGSize(width: 320, height: 1024)]
for size in sizes {
    for landscape in [false, true] {
        let viewport = CGRect(x: 20, y: 44, width: landscape ? size.height : size.width,
                              height: landscape ? size.width : size.height)
        let layout = ConsoleShellGeometry(in: viewport, spread: landscape)
        let visible = viewport.insetBy(dx: -0.01, dy: -0.01)
        for rect in [layout.upperPanel, layout.lowerPanel, layout.topScreen, layout.bottomScreen,
                     layout.circlePad, layout.cStick, layout.select, layout.menu, layout.start]
                    + layout.faceButtons + layout.dpad + layout.shoulders {
            check(visible.contains(rect), "Clipped frame \(rect) in \(viewport)")
        }
        check(abs(layout.topScreen.width / layout.topScreen.height - 5.0 / 3) < 0.001, "Upper LCD distorted")
        check(abs(layout.bottomScreen.width / layout.bottomScreen.height - 4.0 / 3) < 0.001, "Lower LCD distorted")
        if landscape {
            check(layout.upperPanel.maxX < layout.lowerPanel.minX, "Landscape panels overlap")
        } else {
            check(abs(layout.upperPanel.maxY - layout.lowerPanel.minY) < 0.001, "Portrait hinge has a gap")
        }
    }
}
print("Adaptive layout: \(checks) checks passed across \(sizes.count * 2) viewports")

// Input: fixed skin profiles and common portrait viewport sizes.
// Output: measured frame alignment, visibility and native LCD checks.
// Pos: layout checks run before release packaging.
import Foundation
import CoreGraphics

var checks = 0
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
    checks += 1
}
let profiles: [ConsoleSkinProfile] = [.duo, .tallPhone, .classicPhone, .tablet]
for profile in profiles {
    let source = CGRect(origin: .zero, size: profile.size)
    for rect in [profile.top, profile.bottom, profile.pad, profile.cStick, profile.cross]
        + profile.faces + profile.footer {
        check(source.contains(rect), "Source coordinates outside \(profile.asset): \(rect)")
    }
}
check(ConsoleSkinProfile.choose(isFoldable: true, isPad: false, ratio: 0.7).asset == ConsoleSkinProfile.duo.asset, "Duo profile")
check(ConsoleSkinProfile.choose(isFoldable: false, isPad: true, ratio: 0.7).asset == ConsoleSkinProfile.tablet.asset, "Tablet profile")
check(ConsoleSkinProfile.choose(isFoldable: false, isPad: false, ratio: 0.46).asset == ConsoleSkinProfile.tallPhone.asset, "Tall phone profile")
check(ConsoleSkinProfile.choose(isFoldable: false, isPad: false, ratio: 0.56).asset == ConsoleSkinProfile.classicPhone.asset, "Classic phone profile")
let cases: [(ConsoleSkinProfile, CGSize)] = [
    (.classicPhone, CGSize(width: 320, height: 568)), (.classicPhone, CGSize(width: 375, height: 667)),
    (.tallPhone, CGSize(width: 393, height: 852)), (.tallPhone, CGSize(width: 430, height: 932)),
    (.tablet, CGSize(width: 768, height: 1024)), (.tablet, CGSize(width: 834, height: 1194)),
    (.tablet, CGSize(width: 1024, height: 1366))]
for (profile, size) in cases {
    let viewport = CGRect(origin: CGPoint(x: 20, y: 44), size: size)
    let layout = ConsoleShellGeometry(profile: profile, in: viewport)
    let visible = viewport.insetBy(dx: -0.01, dy: -0.01)
    for rect in [layout.area, layout.topScreen, layout.bottomScreen, layout.circlePad, layout.cStick,
                 layout.select, layout.menu, layout.start] + layout.faceButtons + layout.dpad + layout.shoulders {
        check(visible.contains(rect), "Clipped frame \(rect) in \(profile.asset)")
    }
    check(abs(layout.topScreen.width / layout.topScreen.height - 5.0 / 3) < 0.001, "Upper LCD distorted")
    check(abs(layout.bottomScreen.width / layout.bottomScreen.height - 4.0 / 3) < 0.001, "Lower LCD distorted")
    check(!layout.bottomScreen.intersects(layout.circlePad), "LCD overlaps Circle Pad")
    for (source, frame) in zip(profile.faces, layout.faceButtons) {
        check(!layout.bottomScreen.intersects(frame), "LCD overlaps action button")
        let scale = layout.area.width / profile.size.width
        check(abs(frame.midX - layout.area.minX - source.midX * scale) < 0.001, "Action X misaligned")
        check(abs(frame.midY - layout.area.minY - source.midY * scale) < 0.001, "Action Y misaligned")
    }
}
print("Fixed skin layout: \(checks) checks passed across \(profiles.count) profiles and \(cases.count) viewports")

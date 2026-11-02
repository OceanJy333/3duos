// Input: fixed generated skins and their measured screen/control coordinates.
// Output: one skin profile for Duo, tall iPhone, 16:9 iPhone or iPad.
// Pos: the single source of artwork alignment; no internal responsive layout.
import Foundation
import CoreGraphics

struct ConsoleSkinProfile {
    let asset: String
    let size: CGSize
    let top: CGRect
    let bottom: CGRect
    let pad: CGRect
    let cStick: CGRect
    let cross: CGRect
    let faces: [CGRect] // X, Y, A, B
    let footer: [CGRect] // Select, HOME, Start
    let hingeY: CGFloat

    private static func key(_ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat) -> CGRect {
        CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
    }

    static let duo = ConsoleSkinProfile(
        asset: "New3DSWhiteFaceplateXLAllWhite", size: CGSize(width: 1052, height: 1495),
        top: CGRect(x: 75, y: 96, width: 900, height: 540),
        bottom: CGRect(x: 215, y: 828, width: 620, height: 504),
        pad: CGRect(x: 28, y: 878, width: 164, height: 174),
        cStick: CGRect(x: 877, y: 852, width: 73, height: 74),
        cross: CGRect(x: 42, y: 1081, width: 135, height: 145),
        faces: [key(944.5, 970, 63), key(889.5, 1029.5, 63), key(998.5, 1029.5, 63), key(944.5, 1090, 63)],
        footer: [CGRect(x: 252, y: 1359, width: 164, height: 57),
                 CGRect(x: 463, y: 1359, width: 124, height: 57),
                 CGRect(x: 634, y: 1359, width: 163, height: 57)], hingeY: 750)

    static let tallPhone = ConsoleSkinProfile(
        asset: "White3DSTallPhone", size: CGSize(width: 830, height: 1896),
        top: CGRect(x: 58, y: 146, width: 714, height: 396),
        bottom: CGRect(x: 124, y: 800, width: 582, height: 473),
        pad: CGRect(x: 32, y: 1325, width: 184, height: 184),
        cStick: CGRect(x: 649, y: 1327, width: 80, height: 80),
        cross: CGRect(x: 47, y: 1524, width: 150, height: 157),
        faces: [key(688.5, 1460, 73), key(619.5, 1526, 73), key(758.5, 1526, 73), key(688.5, 1594, 73)],
        footer: [CGRect(x: 167, y: 1728, width: 144, height: 64),
                 CGRect(x: 348, y: 1728, width: 134, height: 64),
                 CGRect(x: 518, y: 1728, width: 144, height: 64)], hingeY: 650)

    static let classicPhone = ConsoleSkinProfile(
        asset: "White3DSClassicPhone", size: CGSize(width: 941, height: 1672),
        top: CGRect(x: 79, y: 154, width: 784, height: 450),
        bottom: CGRect(x: 211, y: 996, width: 519, height: 392),
        pad: CGRect(x: 20, y: 973, width: 167, height: 174),
        cStick: CGRect(x: 771, y: 946, width: 78, height: 80),
        cross: CGRect(x: 33, y: 1197, width: 137, height: 160),
        faces: [key(842.5, 1077, 67), key(792.5, 1140, 67), key(892.5, 1140, 67), key(842.5, 1203.5, 67)],
        footer: [CGRect(x: 227, y: 1507, width: 142, height: 65),
                 CGRect(x: 406, y: 1507, width: 129, height: 65),
                 CGRect(x: 571, y: 1507, width: 143, height: 65)], hingeY: 800)

    static let tablet = ConsoleSkinProfile(
        asset: "White3DSTablet", size: CGSize(width: 1086, height: 1448),
        top: CGRect(x: 81, y: 110, width: 924, height: 493),
        bottom: CGRect(x: 215, y: 812, width: 656, height: 462),
        pad: CGRect(x: 21, y: 857, width: 179, height: 175),
        cStick: CGRect(x: 913, y: 830, width: 73, height: 76),
        cross: CGRect(x: 40, y: 1054, width: 134, height: 142),
        faces: [key(980, 951, 63), key(926, 1009, 63), key(1034, 1009, 63), key(979.5, 1068, 63)],
        footer: [CGRect(x: 266, y: 1304, width: 165, height: 62),
                 CGRect(x: 468, y: 1304, width: 150, height: 62),
                 CGRect(x: 655, y: 1304, width: 166, height: 62)], hingeY: 705)

    static func choose(isFoldable: Bool, isPad: Bool, ratio: CGFloat) -> ConsoleSkinProfile {
        if isFoldable { return duo }
        if isPad { return tablet }
        return ratio < 0.51 ? tallPhone : classicPhone
    }
}

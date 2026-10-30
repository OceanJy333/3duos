// input: two frames of the same top-screen draw whose shader uniform moves the quad between them.
// output: assertions that the renderer's LCD motion plane equals previous minus current position, in LCD pixels.
// pos: ground-truth check for the MetalFX motion source (PICAMotionTracker), independent of any game.
import Foundation

func rendererMotionChecks() {
    let scene = Scene()
    scene.renderer.emitsMotionInputs = true
    scene.renderer.jittersTopScreen = false
    scene.write(texturePhysical, [UInt8](repeating: 255, count: 256))
    scene.run { configure(scene, &$0, width: 240, height: 400) }
    scene.upload(quad(8, 8, 40, 40, z: -0.5, color: [255, 255, 255, 255]))
    func frame(shift: Float) {
        scene.run {
            // Uniform 0 is the x row of the matrix: x' = x + shift (NDC), i.e. shift * 120 target pixels along target x.
            $0.write(PICAReg.uniformIndex, 0)
            $0.upload(PICAReg.uniformData, packUniform(1, 0, 0, shift))
            $0.write(PICAReg.vertexCount, 6); $0.write(PICAReg.vertexOffset, 0); $0.write(PICAReg.drawArrays, 1)
        }
        scene.renderer.finishFrame()
    }
    frame(shift: 0)
    frame(shift: 0.1)
    // Target x grows against the LCD row: a +12 px shift in x is a -12 row move, so previous minus current is +12 rows.
    let (row, column) = (239 - 60, 100)
    let m = scene.renderer.motion.lcdMotion[row * 400 + column]
    rcheck(abs(m.x) < 0.05 && abs(m.y - 12) < 0.05, "uniform shift of 12 target px reprojects to (0, +12) LCD px, got \(m)")
    rcheck(scene.renderer.motion.lcdMotion[10 * 400 + 10] == .zero, "empty pixels report no motion")
    frame(shift: 0.1)
    let still = scene.renderer.motion.lcdMotion[row * 400 + column]
    rcheck(abs(still.x) < 0.05 && abs(still.y) < 0.05, "unchanged uniforms report zero motion, got \(still)")
}

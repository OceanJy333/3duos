// Input: a synthetic RGBA texture on the local Metal device.
// Output: a GPU completion and readback check of four scaled color regions.
// Pos: standalone Metal 4 MetalFX Spatial experiment, independent of the app.
import Foundation
import Metal
import MetalFX

let device = MTLCreateSystemDefaultDevice()!
guard MTLFXSpatialScalerDescriptor.supportsMetal4FX(device) else {
    print("SKIP: \(device.name) does not support Metal 4 MetalFX Spatial")
    exit(0)
}
let width = 64, height = 64, outWidth = 128, outHeight = 128
let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
descriptor.storageMode = .shared
descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
let input = device.makeTexture(descriptor: descriptor)!
var pixels = [UInt8](repeating: 0, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        let color: [UInt8] = y < height / 2 ? (x < width / 2 ? [255, 0, 0] : [0, 255, 0])
                                               : (x < width / 2 ? [0, 0, 255] : [255, 255, 0])
        pixels.replaceSubrange(offset..<offset + 4, with: color + [255])
    }
}
pixels.withUnsafeBytes {
    input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                  withBytes: $0.baseAddress!, bytesPerRow: width * 4)
}
do {
    _ = try MetalFXSpatial(device: device, input: input, outputWidth: width - 1, outputHeight: height)
    fatalError("Downscaling was accepted")
} catch MetalFXSpatialError.invalidSize {}
let unusableDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
unusableDescriptor.textureType = .type2DArray
unusableDescriptor.arrayLength = 2
unusableDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
let unusable = device.makeTexture(descriptor: unusableDescriptor)!
do {
    _ = try MetalFXSpatial(device: device, input: unusable, outputWidth: outWidth, outputHeight: outHeight)
    fatalError("2D array input was accepted")
} catch MetalFXSpatialError.incompatibleInput {}
let spatial = try MetalFXSpatial(device: device, input: input, outputWidth: outWidth, outputHeight: outHeight)
precondition(spatial.output.width == outWidth && spatial.output.height == outHeight)
let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
residency.addAllocation(input)
residency.addAllocation(spatial.output)
residency.commit()
let queue = device.makeMTL4CommandQueue()!
queue.addResidencySet(residency)
let allocator = device.makeCommandAllocator()!
let command = device.makeCommandBuffer()!
command.beginCommandBuffer(allocator: allocator)
spatial.encode(to: command)
command.endCommandBuffer()
queue.commit([command])
let event = device.makeSharedEvent()!
queue.signalEvent(event, value: 1)
precondition(event.wait(untilSignaledValue: 1, timeoutMS: 10_000), "Metal 4 GPU did not complete")

let readback = device.makeBuffer(length: outWidth * outHeight * 4, options: .storageModeShared)!
let readCommand = device.makeCommandQueue()!.makeCommandBuffer()!
let blit = readCommand.makeBlitCommandEncoder()!
blit.copy(from: spatial.output, sourceSlice: 0, sourceLevel: 0,
          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: outWidth, height: outHeight, depth: 1),
          to: readback, destinationOffset: 0, destinationBytesPerRow: outWidth * 4,
          destinationBytesPerImage: outWidth * outHeight * 4)
blit.endEncoding()
readCommand.commit()
readCommand.waitUntilCompleted()
precondition(readCommand.status == .completed, "Readback failed: \(String(describing: readCommand.error))")
let result = readback.contents().bindMemory(to: UInt8.self, capacity: outWidth * outHeight * 4)
for (x, y, expected) in [(32, 32, [255, 0, 0]), (96, 32, [0, 255, 0]),
                          (32, 96, [0, 0, 255]), (96, 96, [255, 255, 0])] {
    let offset = (y * outWidth + x) * 4
    let actual = (0..<4).map { Int(result[offset + $0]) }
    precondition(zip(actual.prefix(3), expected).allSatisfy { abs($0 - $1) <= 8 } && actual[3] >= 247,
                 "Unexpected pixel at \(x),\(y): \(actual), expected \(expected)")
    print("(\(x),\(y)): \(actual)")
}
print("PASS: Metal 4 MetalFX Spatial \(width)x\(height) -> \(outWidth)x\(outHeight) on \(device.name)")

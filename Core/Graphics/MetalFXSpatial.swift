// Input: a Metal device, input texture, target size, and a recording Metal 4 command buffer.
// Output: a private output texture and encoded MetalFX spatial upscaling work.
// Pos: independent rendering primitive; its caller owns residency, submission, and synchronization.
import Metal
import MetalFX

@available(iOS 26.0, macOS 26.0, *)
enum MetalFXSpatialError: Error {
    case unsupported, invalidSize, incompatibleInput, creationFailed
}

@available(iOS 26.0, macOS 26.0, *)
final class MetalFXSpatial {
    let output: MTLTexture
    private let scaler: MTL4FXSpatialScaler
    private let input: MTLTexture

    init(device: MTLDevice, input: MTLTexture, outputWidth: Int, outputHeight: Int) throws {
        guard MTLFXSpatialScalerDescriptor.supportsMetal4FX(device) else {
            throw MetalFXSpatialError.unsupported
        }
        guard outputWidth >= input.width, outputHeight >= input.height,
              outputWidth > 0, outputHeight > 0 else { throw MetalFXSpatialError.invalidSize }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = input.pixelFormat
        descriptor.outputTextureFormat = input.pixelFormat
        descriptor.inputWidth = input.width
        descriptor.inputHeight = input.height
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorProcessingMode = .perceptual
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        guard let scaler = descriptor.makeSpatialScaler(device: device, compiler: compiler) else {
            throw MetalFXSpatialError.creationFailed
        }
        guard input.device === device, input.textureType == .type2D,
              input.usage.contains(scaler.colorTextureUsage) else {
            throw MetalFXSpatialError.incompatibleInput
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat, width: outputWidth, height: outputHeight, mipmapped: false)
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let output = device.makeTexture(descriptor: outputDescriptor) else {
            throw MetalFXSpatialError.creationFailed
        }
        self.input = input
        self.output = output
        self.scaler = scaler
    }

    func encode(to commandBuffer: MTL4CommandBuffer) {
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        scaler.encode(commandBuffer: commandBuffer)
    }
}

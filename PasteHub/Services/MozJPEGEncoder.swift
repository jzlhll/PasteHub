import AppKit

enum MozJPEGEncoder {
    static func encodedData(from image: CGImage, quality: Int) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 65_500, height <= 65_500,
              quality >= 1, quality <= 100 else { return nil }
        let bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                          | CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)

        var output: UnsafeMutablePointer<UInt8>?
        var outputSize = 0
        var message = [CChar](repeating: 0, count: 256)
        let result = ph_mozjpeg_encode_rgba(pixels.assumingMemoryBound(to: UInt8.self), width, height,
                                            bytesPerRow, Int32(quality), &output, &outputSize,
                                            &message, message.count)
        guard result != 0, let output else {
            NSLog("MozJPEG encoding failed: %@", String(cString: message))
            return nil
        }
        return Data(bytesNoCopy: output, count: outputSize, deallocator: .free)
    }
}

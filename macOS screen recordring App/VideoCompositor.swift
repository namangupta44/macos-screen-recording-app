import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

final class VideoCompositor {
    private let context = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func render(
        screenPixelBuffer: CVPixelBuffer,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        into destinationPixelBuffer: CVPixelBuffer,
        outputSize: CGSize
    ) {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let finalImage = composedImage(
            screenImage: CIImage(cvPixelBuffer: screenPixelBuffer),
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            outputRect: outputRect
        )
        context.render(finalImage, to: destinationPixelBuffer, bounds: outputRect, colorSpace: colorSpace)
    }

    func previewImage(
        screenImage: CGImage,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        outputSize: CGSize
    ) -> CGImage? {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let finalImage = composedImage(
            screenImage: CIImage(cgImage: screenImage),
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            outputRect: outputRect
        )

        return context.createCGImage(finalImage, from: outputRect)
    }

    func previewImage(
        screenPixelBuffer: CVPixelBuffer,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        outputSize: CGSize
    ) -> CGImage? {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let finalImage = composedImage(
            screenImage: CIImage(cvPixelBuffer: screenPixelBuffer),
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            outputRect: outputRect
        )

        return context.createCGImage(finalImage, from: outputRect)
    }

    private func composedImage(
        screenImage: CIImage,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        outputRect: CGRect
    ) -> CIImage {
        var finalImage = fitScreenImage(screenImage, into: outputRect)

        if let cameraPixelBuffer, let overlayImage = makeOverlayImage(from: CIImage(cvPixelBuffer: cameraPixelBuffer), overlay: overlay, outputRect: outputRect) {
            finalImage = overlayImage.composited(over: finalImage)
        }

        return finalImage
    }

    private func fitScreenImage(_ image: CIImage, into outputRect: CGRect) -> CIImage {
        let scale = min(outputRect.width / image.extent.width, outputRect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = outputRect.midX - (scaled.extent.width / 2)
        let y = outputRect.midY - (scaled.extent.height / 2)

        return scaled
            .transformed(by: CGAffineTransform(translationX: x - scaled.extent.minX, y: y - scaled.extent.minY))
            .composited(over: CIImage(color: .black).cropped(to: outputRect))
    }

    private func makeOverlayImage(from image: CIImage, overlay: OverlayLayout, outputRect: CGRect) -> CIImage? {
        let side = min(outputRect.width, outputRect.height) * overlay.sizeFraction
        guard side > 0 else { return nil }

        let squareSide = min(image.extent.width, image.extent.height)
        let squareCrop = CGRect(
            x: image.extent.midX - (squareSide / 2),
            y: image.extent.midY - (squareSide / 2),
            width: squareSide,
            height: squareSide
        )

        let cropped = image.cropped(to: squareCrop)
        let scale = side / squareSide
        let resized = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = CGPoint(
            x: (outputRect.width * overlay.normalizedCenter.x) - (side / 2),
            y: (outputRect.height * overlay.normalizedCenter.y) - (side / 2)
        )
        let translated = resized.transformed(by: CGAffineTransform(translationX: origin.x - resized.extent.minX, y: origin.y - resized.extent.minY))
        let overlayFrame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        guard let mask = shapeMask(side: side, shape: overlay.shape)?
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        else {
            return nil
        }

        let background = CIImage(color: .clear).cropped(to: outputRect)
        let clippedCamera = translated.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputMaskImageKey: mask,
                kCIInputBackgroundImageKey: background
            ]
        )

        var overlayImage = clippedCamera

        if let shadow = shadowImage(mask: mask, borderStyle: overlay.borderStyle, frame: overlayFrame, outputRect: outputRect) {
            overlayImage = overlayImage.composited(over: shadow)
        }

        if let border = borderImage(side: side, shape: overlay.shape, borderStyle: overlay.borderStyle)?
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)) {
            overlayImage = border.composited(over: overlayImage)
        }

        return overlayImage
    }

    private func shapeMask(side: CGFloat, shape: OverlayShape) -> CIImage? {
        renderShapeImage(side: side, shape: shape, fillColor: .white, strokeColor: nil, lineWidth: 0)
    }

    private func borderImage(side: CGFloat, shape: OverlayShape, borderStyle: OverlayBorderStyle) -> CIImage? {
        guard borderStyle != .none else { return nil }

        let lineWidth = borderStyle.lineWidth(for: side)
        return renderShapeImage(
            side: side,
            shape: shape,
            fillColor: nil,
            strokeColor: borderStyle.cgColor,
            lineWidth: lineWidth
        )
    }

    private func shadowImage(mask: CIImage, borderStyle: OverlayBorderStyle, frame: CGRect, outputRect: CGRect) -> CIImage? {
        guard borderStyle.shadowOpacity > 0 else { return nil }

        let shadowBase = CIImage(color: borderStyle.shadowColor)
            .cropped(to: frame)
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputMaskImageKey: mask,
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: outputRect)
                ]
            )

        return shadowBase
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: borderStyle.shadowRadius(for: frame.width)])
            .transformed(by: CGAffineTransform(translationX: 0, y: -frame.width * 0.025))
            .cropped(to: outputRect)
    }

    private func renderShapeImage(
        side: CGFloat,
        shape: OverlayShape,
        fillColor: CGColor?,
        strokeColor: CGColor?,
        lineWidth: CGFloat
    ) -> CIImage? {
        let imageSize = CGSize(width: ceil(side), height: ceil(side))
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: Int(imageSize.width),
            height: Int(imageSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.clear(CGRect(origin: .zero, size: imageSize))

        let inset = max(lineWidth / 2, 0)
        let rect = CGRect(origin: .zero, size: imageSize).insetBy(dx: inset, dy: inset)
        let path = shape.path(in: rect)

        if let fillColor {
            context.addPath(path)
            context.setFillColor(fillColor)
            context.fillPath()
        }

        if let strokeColor, lineWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

private extension OverlayShape {
    func path(in rect: CGRect) -> CGPath {
        switch self {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedSquare:
            return CGPath(
                roundedRect: rect,
                cornerWidth: min(rect.width, rect.height) * 0.22,
                cornerHeight: min(rect.width, rect.height) * 0.22,
                transform: nil
            )
        case .square:
            return CGPath(rect: rect, transform: nil)
        }
    }
}

private extension OverlayBorderStyle {
    var cgColor: CGColor {
        switch self {
        case .soft:
            return CGColor(red: 1, green: 1, blue: 1, alpha: 0.72)
        case .studio:
            return CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        case .glow:
            return CGColor(red: 0.45, green: 0.78, blue: 1, alpha: 0.95)
        case .none:
            return CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        }
    }

    var shadowOpacity: CGFloat {
        switch self {
        case .soft:
            return 0.2
        case .studio:
            return 0.28
        case .glow:
            return 0.35
        case .none:
            return 0
        }
    }

    var shadowColor: CIColor {
        switch self {
        case .soft:
            return CIColor(red: 0, green: 0, blue: 0, alpha: shadowOpacity)
        case .studio:
            return CIColor(red: 0, green: 0, blue: 0, alpha: shadowOpacity)
        case .glow:
            return CIColor(red: 0.2, green: 0.65, blue: 1, alpha: shadowOpacity)
        case .none:
            return CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    func lineWidth(for side: CGFloat) -> CGFloat {
        switch self {
        case .soft:
            return max(2, side * 0.018)
        case .studio:
            return max(3, side * 0.03)
        case .glow:
            return max(3, side * 0.024)
        case .none:
            return 0
        }
    }

    func shadowRadius(for side: CGFloat) -> CGFloat {
        switch self {
        case .soft:
            return max(4, side * 0.04)
        case .studio:
            return max(6, side * 0.055)
        case .glow:
            return max(8, side * 0.08)
        case .none:
            return 0
        }
    }
}

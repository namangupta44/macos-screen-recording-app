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
        let diameter = min(outputRect.width, outputRect.height) * overlay.sizeFraction
        guard diameter > 0 else { return nil }

        let squareSide = min(image.extent.width, image.extent.height)
        let squareCrop = CGRect(
            x: image.extent.midX - (squareSide / 2),
            y: image.extent.midY - (squareSide / 2),
            width: squareSide,
            height: squareSide
        )

        let cropped = image.cropped(to: squareCrop)
        let scale = diameter / squareSide
        let resized = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = CGPoint(
            x: (outputRect.width * overlay.normalizedCenter.x) - (diameter / 2),
            y: (outputRect.height * overlay.normalizedCenter.y) - (diameter / 2)
        )
        let translated = resized.transformed(by: CGAffineTransform(translationX: origin.x - resized.extent.minX, y: origin.y - resized.extent.minY))

        let mask = radialMask(center: CGPoint(x: origin.x + (diameter / 2), y: origin.y + (diameter / 2)), radius: diameter / 2)
            .cropped(to: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)))

        return translated.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputMaskImageKey: mask,
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: outputRect)
            ]
        )
    }

    private func radialMask(center: CGPoint, radius: CGFloat) -> CIImage {
        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = Float(max(0, radius - 1))
        filter.radius1 = Float(radius)
        filter.color0 = .white
        filter.color1 = .clear
        return filter.outputImage ?? CIImage.empty()
    }
}

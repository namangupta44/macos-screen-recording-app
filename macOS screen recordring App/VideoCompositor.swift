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
        cursor: CursorFrameState?,
        into destinationPixelBuffer: CVPixelBuffer,
        outputSize: CGSize
    ) {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let finalImage = composedImage(
            screenImage: CIImage(cvPixelBuffer: screenPixelBuffer),
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            cursor: cursor,
            outputRect: outputRect
        )
        context.render(finalImage, to: destinationPixelBuffer, bounds: outputRect, colorSpace: colorSpace)
    }

    func previewImage(
        screenImage: CGImage,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        cursor: CursorFrameState? = nil,
        outputSize: CGSize
    ) -> CGImage? {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let finalImage = composedImage(
            screenImage: CIImage(cgImage: screenImage),
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            cursor: cursor,
            outputRect: outputRect
        )

        return context.createCGImage(finalImage, from: outputRect)
    }

    func previewImage(
        screenPixelBuffer: CVPixelBuffer,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        cursor: CursorFrameState? = nil,
        outputSize: CGSize
    ) -> CGImage? {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let finalImage = composedImage(
            screenImage: CIImage(cvPixelBuffer: screenPixelBuffer),
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            cursor: cursor,
            outputRect: outputRect
        )

        return context.createCGImage(finalImage, from: outputRect)
    }

    private func composedImage(
        screenImage: CIImage,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        cursor: CursorFrameState?,
        outputRect: CGRect
    ) -> CIImage {
        let fittedScreen = fitScreenImage(screenImage, into: outputRect)
        var finalImage = fittedScreen.image

        var cursorPoint = cursor.map { point(for: $0, in: fittedScreen.contentFrame) }
        if let cursor, let point = cursorPoint, cursor.settings.isZoomEnabled {
            let zoomed = zoomedImage(finalImage, around: point, settings: cursor.settings, outputRect: outputRect)
            finalImage = zoomed.image
            cursorPoint = zoomed.cursorPoint
        }

        if let cursor, let point = cursorPoint, let cursorImage = makeCursorEffectsImage(cursor: cursor, at: point, outputRect: outputRect) {
            finalImage = cursorImage.composited(over: finalImage)
        }

        if let cameraPixelBuffer, let overlayImage = makeOverlayImage(from: CIImage(cvPixelBuffer: cameraPixelBuffer), overlay: overlay, outputRect: outputRect) {
            finalImage = overlayImage.composited(over: finalImage)
        }

        return finalImage
    }

    private func fitScreenImage(_ image: CIImage, into outputRect: CGRect) -> FittedScreenImage {
        let scale = min(outputRect.width / image.extent.width, outputRect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = outputRect.midX - (scaled.extent.width / 2)
        let y = outputRect.midY - (scaled.extent.height / 2)
        let contentFrame = CGRect(x: x, y: y, width: scaled.extent.width, height: scaled.extent.height)
        let fitted = scaled.transformed(by: CGAffineTransform(translationX: x - scaled.extent.minX, y: y - scaled.extent.minY))

        return FittedScreenImage(
            image: fitted.composited(over: CIImage(color: .black).cropped(to: outputRect)),
            contentFrame: contentFrame
        )
    }

    private func point(for cursor: CursorFrameState, in contentFrame: CGRect) -> CGPoint {
        CGPoint(
            x: contentFrame.minX + (contentFrame.width * cursor.normalizedLocation.x),
            y: contentFrame.minY + (contentFrame.height * cursor.normalizedLocation.y)
        )
    }

    private func zoomedImage(
        _ image: CIImage,
        around cursorPoint: CGPoint,
        settings: CursorEffectSettings,
        outputRect: CGRect
    ) -> (image: CIImage, cursorPoint: CGPoint) {
        let scale = settings.zoomScale.clamped(to: CursorEffectSettings.zoomScaleRange)
        guard scale > 1.01 else { return (image, cursorPoint) }

        let cropSize = CGSize(width: outputRect.width / scale, height: outputRect.height / scale)
        let cropOrigin = CGPoint(
            x: (cursorPoint.x - (cropSize.width / 2)).clamped(to: outputRect.minX...(outputRect.maxX - cropSize.width)),
            y: (cursorPoint.y - (cropSize.height / 2)).clamped(to: outputRect.minY...(outputRect.maxY - cropSize.height))
        )
        let cropRect = CGRect(origin: cropOrigin, size: cropSize)
        let zoomed = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: outputRect)
            .composited(over: CIImage(color: .black).cropped(to: outputRect))
        let adjustedCursorPoint = CGPoint(
            x: (cursorPoint.x - cropRect.minX) * scale,
            y: (cursorPoint.y - cropRect.minY) * scale
        )

        return (zoomed, adjustedCursorPoint)
    }

    private func makeCursorEffectsImage(cursor: CursorFrameState, at point: CGPoint, outputRect: CGRect) -> CIImage? {
        let minDimension = min(outputRect.width, outputRect.height)
        var effectImage: CIImage?

        if cursor.settings.isHighlightEnabled {
            let radius = minDimension * 0.035
            if let halo = circleImage(
                radius: radius,
                fillColor: CGColor(red: 1.0, green: 0.82, blue: 0.16, alpha: 0.22),
                strokeColor: CGColor(red: 1.0, green: 0.74, blue: 0.08, alpha: 0.82),
                lineWidth: max(3, radius * 0.08)
            )?.translated(toCenter: point) {
                effectImage = halo.composited(over: effectImage ?? CIImage.empty())
            }
        }

        if let progress = cursor.leftClickProgress {
            effectImage = addClickRing(
                to: effectImage,
                at: point,
                progress: progress,
                color: CGColor(red: 1.0, green: 0.72, blue: 0.06, alpha: 1.0)
            )
        }

        if let progress = cursor.rightClickProgress {
            effectImage = addClickRing(
                to: effectImage,
                at: point,
                progress: progress,
                color: CGColor(red: 0.26, green: 0.78, blue: 1.0, alpha: 1.0)
            )
        }

        if let cursorImage = makeCursorImage(settings: cursor.settings, outputRect: outputRect)?
            .translated(toHotspot: point) {
            effectImage = cursorImage.composited(over: effectImage ?? CIImage.empty())
        }

        return effectImage
    }

    private func addClickRing(to image: CIImage?, at point: CGPoint, progress: CGFloat, color: CGColor) -> CIImage? {
        let clampedProgress = progress.clamped(to: 0...1)
        let radius = 22 + (58 * clampedProgress)
        let alpha = max(0, 1 - clampedProgress)
        guard let ring = circleImage(
            radius: radius,
            fillColor: nil,
            strokeColor: color.copy(alpha: alpha),
            lineWidth: max(4, 8 * (1 - clampedProgress))
        )?.translated(toCenter: point) else {
            return image
        }

        return ring.composited(over: image ?? CIImage.empty())
    }

    private func circleImage(radius: CGFloat, fillColor: CGColor?, strokeColor: CGColor?, lineWidth: CGFloat) -> CIImage? {
        let side = ceil((radius + lineWidth) * 2)
        guard side > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: Int(side),
            height: Int(side),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))

        let rect = CGRect(x: lineWidth, y: lineWidth, width: side - (lineWidth * 2), height: side - (lineWidth * 2))
        if let fillColor {
            context.setFillColor(fillColor)
            context.fillEllipse(in: rect)
        }
        if let strokeColor, lineWidth > 0 {
            context.setStrokeColor(strokeColor)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        }

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func makeCursorImage(settings: CursorEffectSettings, outputRect: CGRect) -> CursorImage? {
        let minDimension = min(outputRect.width, outputRect.height)
        let height = max(28, minDimension * 0.044 * settings.cursorScale)
        let width = height * 0.72
        let padding = max(4, height * 0.08)
        let imageSize = CGSize(width: ceil(width + (padding * 2)), height: ceil(height + (padding * 2)))
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

        let tip = CGPoint(x: padding, y: imageSize.height - padding)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: padding, y: padding + (height * 0.12)))
        path.addLine(to: CGPoint(x: padding + (width * 0.34), y: padding + (height * 0.38)))
        path.addLine(to: CGPoint(x: padding + (width * 0.52), y: padding))
        path.addLine(to: CGPoint(x: padding + (width * 0.74), y: padding + (height * 0.10)))
        path.addLine(to: CGPoint(x: padding + (width * 0.56), y: padding + (height * 0.47)))
        path.addLine(to: CGPoint(x: padding + width, y: padding + (height * 0.47)))
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(CGColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 0.92))
        context.setLineWidth(max(2, height * 0.055))
        context.setLineJoin(.round)
        context.strokePath()

        guard let cgImage = context.makeImage() else { return nil }
        return CursorImage(image: CIImage(cgImage: cgImage), hotspot: tip)
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

private struct FittedScreenImage {
    let image: CIImage
    let contentFrame: CGRect
}

private struct CursorImage {
    let image: CIImage
    let hotspot: CGPoint

    func translated(toHotspot point: CGPoint) -> CIImage {
        image.transformed(
            by: CGAffineTransform(
                translationX: point.x - hotspot.x - image.extent.minX,
                y: point.y - hotspot.y - image.extent.minY
            )
        )
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

private extension CIImage {
    func translated(toCenter center: CGPoint) -> CIImage {
        transformed(
            by: CGAffineTransform(
                translationX: center.x - (extent.width / 2) - extent.minX,
                y: center.y - (extent.height / 2) - extent.minY
            )
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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

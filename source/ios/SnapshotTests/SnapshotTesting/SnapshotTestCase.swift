//
//  SnapshotTestCase.swift
//  VisualSnapshotTests
//
//  Ported from AdaptiveCards-Mobile custom snapshot framework.
//  Adapted for UIKit UIView rendering (Teams-AdaptiveCards-Mobile uses ObjC/UIKit).
//  Zero external dependencies.
//
//  Record baselines:  RECORD_SNAPSHOTS=1 xcodebuild test ...
//  Verify baselines:  xcodebuild test ...
//

#if canImport(UIKit)
import XCTest
import UIKit

/// Result of a snapshot comparison.
public struct SnapshotDiffResult {
    public let passed: Bool
    public let diffPercentage: Double
    public let baselinePath: String?
    public let actualPath: String?
    public let diffPath: String?
    public let message: String
}

/// Device/environment configuration for snapshot rendering.
public struct SnapshotConfiguration: CustomStringConvertible {
    public let name: String
    public let size: CGSize
    public let interfaceStyle: UIUserInterfaceStyle
    public let contentSizeCategory: UIContentSizeCategory
    public let scale: CGFloat

    public var description: String { name }

    public init(
        name: String,
        size: CGSize,
        interfaceStyle: UIUserInterfaceStyle = .light,
        contentSizeCategory: UIContentSizeCategory = .large,
        scale: CGFloat = 2.0
    ) {
        self.name = name
        self.size = size
        self.interfaceStyle = interfaceStyle
        self.contentSizeCategory = contentSizeCategory
        self.scale = scale
    }

    // MARK: - Presets

    public static let iPhoneSE = SnapshotConfiguration(
        name: "iPhoneSE_light",
        size: CGSize(width: 375, height: 667)
    )

    public static let iPhone15Pro = SnapshotConfiguration(
        name: "iPhone15Pro_light",
        size: CGSize(width: 393, height: 852)
    )

    public static let iPhone15ProDark = SnapshotConfiguration(
        name: "iPhone15Pro_dark",
        size: CGSize(width: 393, height: 852),
        interfaceStyle: .dark
    )

    public static let iPhoneAccessibilityLarge = SnapshotConfiguration(
        name: "iPhone15Pro_a11y_xxxl",
        size: CGSize(width: 393, height: 852),
        contentSizeCategory: .accessibilityExtraExtraExtraLarge
    )

    /// Core configurations: light + dark on iPhone 15 Pro
    public static let core: [SnapshotConfiguration] = [
        .iPhone15Pro,
        .iPhone15ProDark
    ]
}

/// Base class for snapshot tests with UIView rendering and pixel-diff comparison.
///
/// Ported from hggzm/AdaptiveCards-Mobile SnapshotTestCase, adapted for UIKit views.
/// Supports record mode (RECORD_SNAPSHOTS=1) and verify mode (default).
open class SnapshotTestCase: XCTestCase {

    // MARK: - Configuration

    /// Tolerance for pixel differences (0.0 = exact match, 1.0 = all pixels different)
    open var snapshotTolerance: Double { 0.01 } // 1%

    /// Whether to record new baselines instead of comparing
    public var recordMode: Bool {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    }

    /// Root directory for snapshot artifacts.
    /// Override with SNAPSHOT_OUTPUT_DIR env var for CI.
    open var snapshotDirectory: String {
        if let envDir = ProcessInfo.processInfo.environment["SNAPSHOT_OUTPUT_DIR"] {
            return envDir
        }
        let testFileURL = URL(fileURLWithPath: #filePath)
        let snapshotTestsDir = testFileURL
            .deletingLastPathComponent()  // SnapshotTesting/
            .deletingLastPathComponent()  // SnapshotTests/
        return snapshotTestsDir.appendingPathComponent("Snapshots").path
    }

    private var baselinesDirectory: String {
        "\(snapshotDirectory)/Baselines"
    }

    private var failuresDirectory: String {
        "\(snapshotDirectory)/Failures"
    }

    private var diffsDirectory: String {
        "\(snapshotDirectory)/Diffs"
    }

    // MARK: - Public API

    /// Captures a snapshot of a UIView and compares against the baseline.
    ///
    /// - Parameters:
    ///   - view: The UIView to snapshot
    ///   - name: Name for the snapshot file
    ///   - configuration: Device/environment configuration
    ///   - file: Source file (auto-filled)
    ///   - line: Source line (auto-filled)
    /// - Returns: The diff result
    @discardableResult
    public func assertSnapshot(
        of view: UIView,
        named name: String,
        configuration: SnapshotConfiguration = .iPhone15Pro,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SnapshotDiffResult {
        let snapshotName = "\(name)_\(configuration.name)"

        guard let actualImage = renderView(view, configuration: configuration) else {
            let result = SnapshotDiffResult(
                passed: false,
                diffPercentage: 1.0,
                baselinePath: nil,
                actualPath: nil,
                diffPath: nil,
                message: "Failed to render view for snapshot: \(snapshotName)"
            )
            XCTFail(result.message, file: file, line: line)
            return result
        }

        let baselinePath = "\(baselinesDirectory)/\(snapshotName).png"

        if recordMode {
            return saveBaseline(actualImage, path: baselinePath, name: snapshotName, file: file, line: line)
        } else {
            return compareSnapshot(actualImage, baselinePath: baselinePath, name: snapshotName, file: file, line: line)
        }
    }

    /// Captures snapshots across multiple configurations
    @discardableResult
    public func assertSnapshots(
        of view: UIView,
        named name: String,
        configurations: [SnapshotConfiguration] = SnapshotConfiguration.core,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SnapshotDiffResult] {
        configurations.map { config in
            assertSnapshot(of: view, named: name, configuration: config, file: file, line: line)
        }
    }

    // MARK: - UIView Rendering

    /// Renders a UIView into a UIImage by embedding it in a UIWindow.
    public func renderView(_ view: UIView, configuration: SnapshotConfiguration) -> UIImage? {
        // Create a window to host the view (needed for layout + trait propagation)
        let window = UIWindow(frame: CGRect(origin: .zero, size: configuration.size))
        window.overrideUserInterfaceStyle = configuration.interfaceStyle

        // Create a container VC for trait collection
        let vc = UIViewController()
        vc.overrideUserInterfaceStyle = configuration.interfaceStyle
        window.rootViewController = vc
        window.makeKeyAndVisible()

        // Add view to the VC's view hierarchy
        view.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: vc.view.topAnchor),
        ])

        // Force layout
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        // Allow any async layout to settle
        for _ in 0..<3 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // Calculate actual content height
        let fittingSize = view.systemLayoutSizeFitting(
            CGSize(width: configuration.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let renderHeight = min(max(fittingSize.height, 100), configuration.size.height)
        let renderSize = CGSize(width: configuration.size.width, height: renderHeight)

        // Render to image
        let format = UIGraphicsImageRendererFormat()
        format.scale = configuration.scale
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)

        let image = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))
            vc.view.layer.render(in: context.cgContext)
        }

        window.isHidden = true
        return image
    }

    /// Renders a UIView into a UIImage at its intrinsic size.
    public func renderViewAtIntrinsicSize(_ view: UIView, width: CGFloat = 393, interfaceStyle: UIUserInterfaceStyle = .light) -> UIImage? {
        let config = SnapshotConfiguration(
            name: "intrinsic",
            size: CGSize(width: width, height: 2000),
            interfaceStyle: interfaceStyle
        )
        return renderView(view, configuration: config)
    }

    // MARK: - Comparison

    private func compareSnapshot(
        _ actualImage: UIImage,
        baselinePath: String,
        name: String,
        file: StaticString,
        line: UInt
    ) -> SnapshotDiffResult {
        guard FileManager.default.fileExists(atPath: baselinePath),
              let baselineData = try? Data(contentsOf: URL(fileURLWithPath: baselinePath)),
              let baselineImage = UIImage(data: baselineData) else {
            let failurePath = "\(failuresDirectory)/\(name)_actual.png"
            saveImage(actualImage, to: failurePath)

            let result = SnapshotDiffResult(
                passed: false,
                diffPercentage: 1.0,
                baselinePath: nil,
                actualPath: failurePath,
                diffPath: nil,
                message: "No baseline found for '\(name)'. Run with RECORD_SNAPSHOTS=1 to create baselines. Actual saved to: \(failurePath)"
            )
            XCTFail(result.message, file: file, line: line)
            return result
        }

        let diffPercentage = computeImageDifference(baselineImage, actualImage)

        if diffPercentage <= snapshotTolerance {
            return SnapshotDiffResult(
                passed: true,
                diffPercentage: diffPercentage,
                baselinePath: baselinePath,
                actualPath: nil,
                diffPath: nil,
                message: "Snapshot '\(name)' matches baseline (diff: \(String(format: "%.4f%%", diffPercentage * 100)))"
            )
        } else {
            let actualPath = "\(failuresDirectory)/\(name)_actual.png"
            let diffPath = "\(diffsDirectory)/\(name)_diff.png"

            saveImage(actualImage, to: actualPath)
            if let diffImage = generateDiffImage(baselineImage, actualImage) {
                saveImage(diffImage, to: diffPath)
            }

            let result = SnapshotDiffResult(
                passed: false,
                diffPercentage: diffPercentage,
                baselinePath: baselinePath,
                actualPath: actualPath,
                diffPath: diffPath,
                message: "Snapshot '\(name)' differs from baseline by \(String(format: "%.2f%%", diffPercentage * 100)) (tolerance: \(String(format: "%.2f%%", snapshotTolerance * 100))). Diff saved to: \(diffPath)"
            )
            XCTFail(result.message, file: file, line: line)
            return result
        }
    }

    private func saveBaseline(
        _ image: UIImage,
        path: String,
        name: String,
        file: StaticString,
        line: UInt
    ) -> SnapshotDiffResult {
        saveImage(image, to: path)
        let result = SnapshotDiffResult(
            passed: true,
            diffPercentage: 0,
            baselinePath: path,
            actualPath: nil,
            diffPath: nil,
            message: "Recorded baseline snapshot for '\(name)' at: \(path)"
        )
        print("SNAPSHOT RECORDED: \(result.message)")
        return result
    }

    // MARK: - Image Comparison Engine (ported from AdaptiveCards-Mobile)

    /// Computes the percentage of pixels that differ between two images.
    /// Uses multiple strategies (padding + downsampled) and returns the best match.
    public func computeImageDifference(_ image1: UIImage, _ image2: UIImage) -> Double {
        guard let cgImage1 = image1.cgImage, let cgImage2 = image2.cgImage else {
            return 1.0
        }

        let width1 = cgImage1.width, height1 = cgImage1.height
        let width2 = cgImage2.width, height2 = cgImage2.height
        let maxWidth = max(width1, width2), maxHeight = max(height1, height2)
        let totalPixels = maxWidth * maxHeight
        guard totalPixels > 0 else { return 1.0 }

        let bytesPerPixel = 4
        let channelThreshold: UInt8 = 7

        // Strategy 1: Padding — draw at original size, top-left aligned
        let paddingDiff = compareWithPadding(
            cgImage1, cgImage2,
            maxWidth: maxWidth, maxHeight: maxHeight,
            width1: width1, height1: height1,
            width2: width2, height2: height2,
            totalPixels: totalPixels,
            bytesPerPixel: bytesPerPixel,
            channelThreshold: channelThreshold
        )

        // Strategy 2: Downsampled — compare at 50% resolution
        let downsampledDiff = compareDownsampled(
            cgImage1, cgImage2,
            scaleFactor: 0.5,
            bytesPerPixel: bytesPerPixel,
            channelThreshold: channelThreshold
        )

        // Strategy 3: Color-tolerant — higher threshold for color space differences
        if width1 == width2 && height1 == height2 {
            let colorTolerantDiff = compareWithPadding(
                cgImage1, cgImage2,
                maxWidth: maxWidth, maxHeight: maxHeight,
                width1: width1, height1: height1,
                width2: width2, height2: height2,
                totalPixels: totalPixels,
                bytesPerPixel: bytesPerPixel,
                channelThreshold: 60
            )
            return min(paddingDiff, min(downsampledDiff, colorTolerantDiff))
        }

        // Strategy 4: Crop to overlapping area
        let cropDiff = compareWithCrop(
            cgImage1, cgImage2,
            width1: width1, height1: height1,
            width2: width2, height2: height2,
            bytesPerPixel: bytesPerPixel,
            channelThreshold: channelThreshold
        )

        return min(paddingDiff, min(downsampledDiff, cropDiff))
    }

    // MARK: - Comparison Strategies

    private func compareWithPadding(
        _ cgImage1: CGImage, _ cgImage2: CGImage,
        maxWidth: Int, maxHeight: Int,
        width1: Int, height1: Int,
        width2: Int, height2: Int,
        totalPixels: Int,
        bytesPerPixel: Int,
        channelThreshold: UInt8
    ) -> Double {
        let bytesPerRow = maxWidth * bytesPerPixel
        let bitmapSize = maxHeight * bytesPerRow

        var pixels1 = [UInt8](repeating: 255, count: bitmapSize)
        var pixels2 = [UInt8](repeating: 255, count: bitmapSize)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx1 = CGContext(data: &pixels1, width: maxWidth, height: maxHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctx2 = CGContext(data: &pixels2, width: maxWidth, height: maxHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else { return 1.0 }

        ctx1.draw(cgImage1, in: CGRect(x: 0, y: maxHeight - height1, width: width1, height: height1))
        ctx2.draw(cgImage2, in: CGRect(x: 0, y: maxHeight - height2, width: width2, height: height2))

        return countDifferentPixels(&pixels1, &pixels2, bitmapSize: bitmapSize,
                                    bytesPerPixel: bytesPerPixel, channelThreshold: channelThreshold,
                                    totalPixels: totalPixels)
    }

    private func compareDownsampled(
        _ cgImage1: CGImage, _ cgImage2: CGImage,
        scaleFactor: Double,
        bytesPerPixel: Int,
        channelThreshold: UInt8
    ) -> Double {
        let halfWidth = Int(Double(max(cgImage1.width, cgImage2.width)) * scaleFactor)
        let halfHeight = Int(Double(max(cgImage1.height, cgImage2.height)) * scaleFactor)
        let totalPixels = halfWidth * halfHeight
        guard totalPixels > 0 else { return 1.0 }

        let bytesPerRow = halfWidth * bytesPerPixel
        let bitmapSize = halfHeight * bytesPerRow

        var pixels1 = [UInt8](repeating: 255, count: bitmapSize)
        var pixels2 = [UInt8](repeating: 255, count: bitmapSize)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx1 = CGContext(data: &pixels1, width: halfWidth, height: halfHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctx2 = CGContext(data: &pixels2, width: halfWidth, height: halfHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else { return 1.0 }

        ctx1.interpolationQuality = .high
        ctx2.interpolationQuality = .high
        ctx1.draw(cgImage1, in: CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
        ctx2.draw(cgImage2, in: CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))

        let dsThreshold: UInt8 = 12
        let effectiveThreshold = max(channelThreshold, dsThreshold)

        return countDifferentPixels(&pixels1, &pixels2, bitmapSize: bitmapSize,
                                    bytesPerPixel: bytesPerPixel, channelThreshold: effectiveThreshold,
                                    totalPixels: totalPixels)
    }

    private func compareWithCrop(
        _ cgImage1: CGImage, _ cgImage2: CGImage,
        width1: Int, height1: Int,
        width2: Int, height2: Int,
        bytesPerPixel: Int,
        channelThreshold: UInt8
    ) -> Double {
        let cropWidth = min(width1, width2)
        let cropHeight = min(height1, height2)
        let totalPixels = cropWidth * cropHeight
        guard totalPixels > 0 else { return 1.0 }

        let bytesPerRow = cropWidth * bytesPerPixel
        let bitmapSize = cropHeight * bytesPerRow

        var pixels1 = [UInt8](repeating: 255, count: bitmapSize)
        var pixels2 = [UInt8](repeating: 255, count: bitmapSize)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx1 = CGContext(data: &pixels1, width: cropWidth, height: cropHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctx2 = CGContext(data: &pixels2, width: cropWidth, height: cropHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else { return 1.0 }

        ctx1.draw(cgImage1, in: CGRect(x: 0, y: cropHeight - height1, width: width1, height: height1))
        ctx2.draw(cgImage2, in: CGRect(x: 0, y: cropHeight - height2, width: width2, height: height2))

        return countDifferentPixels(&pixels1, &pixels2, bitmapSize: bitmapSize,
                                    bytesPerPixel: bytesPerPixel, channelThreshold: channelThreshold,
                                    totalPixels: totalPixels)
    }

    private func countDifferentPixels(
        _ pixels1: inout [UInt8], _ pixels2: inout [UInt8],
        bitmapSize: Int, bytesPerPixel: Int, channelThreshold: UInt8, totalPixels: Int
    ) -> Double {
        var differentPixels = 0
        for i in stride(from: 0, to: bitmapSize, by: bytesPerPixel) {
            let rDiff = abs(Int(pixels1[i]) - Int(pixels2[i]))
            let gDiff = abs(Int(pixels1[i+1]) - Int(pixels2[i+1]))
            let bDiff = abs(Int(pixels1[i+2]) - Int(pixels2[i+2]))
            let aDiff = abs(Int(pixels1[i+3]) - Int(pixels2[i+3]))

            if rDiff > Int(channelThreshold) ||
               gDiff > Int(channelThreshold) ||
               bDiff > Int(channelThreshold) ||
               aDiff > Int(channelThreshold) {
                differentPixels += 1
            }
        }
        return Double(differentPixels) / Double(totalPixels)
    }

    /// Generates a visual diff image highlighting differences in red.
    public func generateDiffImage(_ baseline: UIImage, _ actual: UIImage) -> UIImage? {
        guard let cgBaseline = baseline.cgImage, let cgActual = actual.cgImage else {
            return nil
        }

        let maxWidth = max(cgBaseline.width, cgActual.width)
        let maxHeight = max(cgBaseline.height, cgActual.height)
        let bytesPerPixel = 4
        let bytesPerRow = maxWidth * bytesPerPixel
        let bitmapSize = maxHeight * bytesPerRow

        var pixels1 = [UInt8](repeating: 0, count: bitmapSize)
        var pixels2 = [UInt8](repeating: 0, count: bitmapSize)
        var diffPixels = [UInt8](repeating: 0, count: bitmapSize)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx1 = CGContext(data: &pixels1, width: maxWidth, height: maxHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let ctx2 = CGContext(data: &pixels2, width: maxWidth, height: maxHeight,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }

        ctx1.draw(cgBaseline, in: CGRect(x: 0, y: 0, width: cgBaseline.width, height: cgBaseline.height))
        ctx2.draw(cgActual, in: CGRect(x: 0, y: 0, width: cgActual.width, height: cgActual.height))

        let thresh: UInt8 = 3
        for i in stride(from: 0, to: bitmapSize, by: bytesPerPixel) {
            let rDiff = abs(Int(pixels1[i]) - Int(pixels2[i]))
            let gDiff = abs(Int(pixels1[i+1]) - Int(pixels2[i+1]))
            let bDiff = abs(Int(pixels1[i+2]) - Int(pixels2[i+2]))
            let aDiff = abs(Int(pixels1[i+3]) - Int(pixels2[i+3]))

            if rDiff > Int(thresh) || gDiff > Int(thresh) || bDiff > Int(thresh) || aDiff > Int(thresh) {
                diffPixels[i] = 255; diffPixels[i+1] = 0; diffPixels[i+2] = 0; diffPixels[i+3] = 200
            } else {
                diffPixels[i] = UInt8(min(Int(pixels1[i]) / 3 + 170, 255))
                diffPixels[i+1] = UInt8(min(Int(pixels1[i+1]) / 3 + 170, 255))
                diffPixels[i+2] = UInt8(min(Int(pixels1[i+2]) / 3 + 170, 255))
                diffPixels[i+3] = pixels1[i+3]
            }
        }

        guard let diffCtx = CGContext(data: &diffPixels, width: maxWidth, height: maxHeight,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let diffCGImage = diffCtx.makeImage()
        else { return nil }

        return UIImage(cgImage: diffCGImage)
    }

    // MARK: - File I/O

    private func saveImage(_ image: UIImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = image.pngData() {
            try? data.write(to: url)
        }
    }
}
#endif // canImport(UIKit)

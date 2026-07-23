import AppKit
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Vision

private let screenCaptureLogger = HexLog.transcription

@DependencyClient
struct ScreenCaptureClient {
	var captureDisplayUnderCursor: @Sendable (
		_ frameCaptured: @escaping @Sendable () async -> Void
	) async throws -> ScreenContext
}

extension ScreenCaptureClient: DependencyKey {
	static let liveValue = Self(
		captureDisplayUnderCursor: { frameCaptured in
			guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
				throw ScreenCaptureError.permissionDenied
			}
			try Task.checkCancellation()

			let target = try await MainActor.run { try CaptureTarget.displayUnderCursor() }
			try Task.checkCancellation()
			let selection = try await ScreenCaptureSelectionOverlay.selectRegion(
				on: target.screenFrame,
				backingScaleFactor: target.backingScaleFactor
			)
			try Task.checkCancellation()
			guard let displayImage = CGDisplayCreateImage(target.displayID) else {
				throw ScreenCaptureError.captureFailed
			}
			let image: CGImage
			if let selection {
				guard let pixelRect = ScreenCaptureSelection.pixelRect(
					for: selection,
					displayPointSize: target.screenFrame.size,
					backingScaleFactor: target.backingScaleFactor,
					imageSize: CGSize(width: displayImage.width, height: displayImage.height)
				), let croppedImage = displayImage.cropping(to: pixelRect) else {
					throw ScreenCaptureError.captureFailed
				}
				image = croppedImage
			} else {
				image = displayImage
			}
			try Task.checkCancellation()
			await frameCaptured()
			try Task.checkCancellation()

			async let recognizedText = ScreenCaptureProcessing.recognizeText(in: image)
			async let imageData = ScreenCaptureProcessing.encodePNG(image)
			let (resolvedText, resolvedImageData) = try await (recognizedText, imageData)
			try Task.checkCancellation()

			screenCaptureLogger.notice(
				"Captured screen context size=\(image.width)x\(image.height) recognizedCharacters=\(resolvedText.count)"
			)
			return ScreenContext(
				imagePNGData: resolvedImageData,
				recognizedText: resolvedText,
				pixelWidth: image.width,
				pixelHeight: image.height,
				cursorX: target.cursorX,
				cursorY: target.cursorY
			)
		}
	)

	static let testValue = Self()
}

private enum ScreenCaptureProcessing {
	private static let maximumEncodedDimension = 2_048

	static func recognizeText(in image: CGImage) async throws -> String {
		try Task.checkCancellation()
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = true
		try VNImageRequestHandler(cgImage: image).perform([request])
		try Task.checkCancellation()
		let text = request.results?
			.compactMap { $0.topCandidates(1).first?.string }
			.joined(separator: "\n") ?? ""
		try Task.checkCancellation()
		return text
	}

	static func encodePNG(_ image: CGImage) async throws -> Data {
		try Task.checkCancellation()
		let encodedImage = try downsampledImage(from: image)
		try Task.checkCancellation()
		let representation = NSBitmapImageRep(cgImage: encodedImage)
		guard let imageData = representation.representation(using: .png, properties: [:]) else {
			throw ScreenCaptureError.encodingFailed
		}
		try Task.checkCancellation()
		return imageData
	}

	private static func downsampledImage(from image: CGImage) throws -> CGImage {
		let largestDimension = max(image.width, image.height)
		guard largestDimension > maximumEncodedDimension else { return image }

		let scale = Double(maximumEncodedDimension) / Double(largestDimension)
		let width = max(1, Int((Double(image.width) * scale).rounded()))
		let height = max(1, Int((Double(image.height) * scale).rounded()))
		guard let context = CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			throw ScreenCaptureError.encodingFailed
		}
		context.interpolationQuality = .high
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		guard let scaledImage = context.makeImage() else {
			throw ScreenCaptureError.encodingFailed
		}
		return scaledImage
	}
}

private struct CaptureTarget: Sendable {
	let displayID: CGDirectDisplayID
	let cursorX: Double
	let cursorY: Double
	let screenFrame: CGRect
	let backingScaleFactor: CGFloat

	@MainActor
	static func displayUnderCursor() throws -> Self {
		let cursor = NSEvent.mouseLocation
		guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }),
			  let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
		else {
			throw ScreenCaptureError.displayNotFound
		}

		return .init(
			displayID: CGDirectDisplayID(displayNumber.uint32Value),
			cursorX: (cursor.x - screen.frame.minX) * screen.backingScaleFactor,
			cursorY: (cursor.y - screen.frame.minY) * screen.backingScaleFactor,
			screenFrame: screen.frame,
			backingScaleFactor: screen.backingScaleFactor
		)
	}
}

private enum ScreenCaptureError: LocalizedError {
	case permissionDenied
	case displayNotFound
	case captureFailed
	case encodingFailed

	var errorDescription: String? {
		switch self {
		case .permissionDenied:
			"Screen Recording permission is required for screen-aware dictation"
		case .displayNotFound:
			"Could not find the display under the cursor"
		case .captureFailed:
			"Could not capture the display under the cursor"
		case .encodingFailed:
			"Could not prepare the screen capture for analysis"
		}
	}
}

extension DependencyValues {
	var screenCapture: ScreenCaptureClient {
		get { self[ScreenCaptureClient.self] }
		set { self[ScreenCaptureClient.self] = newValue }
	}
}

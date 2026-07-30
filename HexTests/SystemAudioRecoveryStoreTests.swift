import AVFoundation
import XCTest

@testable import Octo

final class SystemAudioRecoveryStoreTests: XCTestCase {
	private var storageRoot: URL!

	override func setUpWithError() throws {
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("SystemAudioRecoveryStoreTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		guard storageRoot.deletingLastPathComponent() == FileManager.default.temporaryDirectory else {
			return XCTFail("Refusing to remove an unexpected test directory")
		}
		try? FileManager.default.removeItem(at: storageRoot)
	}

	func testFinalizedCAFIsTheAuthoritativeRecoverableFile() throws {
		let store = SystemAudioRecoveryStore(storageRoot: storageRoot)
		let parentID = UUID()
		let createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
		let session = try store.begin(parentRecordingSessionID: parentID, createdAt: createdAt)
		let frames = 1_024
		let samples = makeSamples(frameCount: frames)

		try session.appendInterleavedPCM(pcmData(samples), frameCount: frames)
		let finalized = try XCTUnwrap(session.finalize())

		XCTAssertEqual(finalized.parentRecordingSessionID, parentID)
		XCTAssertEqual(finalized.captureID, session.captureID)
		XCTAssertEqual(finalized.duration, Double(frames) / SystemAudioRecoveryStore.sampleRate, accuracy: 0.000_001)
		XCTAssertEqual(finalized.audioURL.pathExtension, "caf")
		try assertReadablePCM(at: finalized.audioURL, expectedSamples: samples, frameCount: frames)
		let activeFiles = try FileManager.default.contentsOfDirectory(
			at: storageRoot.appendingPathComponent("ActiveSystemAudio", isDirectory: true),
			includingPropertiesForKeys: nil
		)
		let recordingFiles = try FileManager.default.contentsOfDirectory(
			at: storageRoot.appendingPathComponent("Recordings", isDirectory: true),
			includingPropertiesForKeys: nil
		)
		XCTAssertTrue(activeFiles.isEmpty)
		XCTAssertEqual(recordingFiles.count, 1, "Finalization must move the authoritative CAF, not copy it")

		let rediscovered = store.recoverInterruptedRecordings()
		XCTAssertEqual(rediscovered.count, 1)
		XCTAssertEqual(
			rediscovered[0].audioURL.resolvingSymlinksInPath(),
			finalized.audioURL.resolvingSymlinksInPath()
		)
		XCTAssertEqual(rediscovered[0].parentRecordingSessionID, parentID)
	}

	func testInterruptedCAFRecoversEveryCompleteFrameAndDropsOnlyTornTailBytes() throws {
		let store = SystemAudioRecoveryStore(storageRoot: storageRoot)
		let parentID = UUID()
		let session = try store.begin(parentRecordingSessionID: parentID)
		let frames = 2_048
		let samples = makeSamples(frameCount: frames)
		try session.appendInterleavedPCM(pcmData(samples), frameCount: frames)
		session.abandonForRecovery()

		let activeDirectory = storageRoot.appendingPathComponent("ActiveSystemAudio", isDirectory: true)
		let activeURL = try XCTUnwrap(
			FileManager.default.contentsOfDirectory(at: activeDirectory, includingPropertiesForKeys: nil).first
		)
		let handle = try FileHandle(forWritingTo: activeURL)
		try handle.seekToEnd()
		try handle.write(contentsOf: Data([0xAA, 0xBB, 0xCC]))
		try handle.synchronize()
		try handle.close()

		let recovered = SystemAudioRecoveryStore(storageRoot: storageRoot).recoverInterruptedRecordings()
		let recording = try XCTUnwrap(recovered.first)
		XCTAssertEqual(recovered.count, 1)
		XCTAssertEqual(recording.parentRecordingSessionID, parentID)
		XCTAssertEqual(recording.duration, Double(frames) / SystemAudioRecoveryStore.sampleRate, accuracy: 0.000_001)
		let fileSize = try XCTUnwrap(
			FileManager.default.attributesOfItem(atPath: recording.audioURL.path)[.size] as? NSNumber
		).intValue
		XCTAssertEqual(fileSize, 68 + frames * SystemAudioRecoveryStore.bytesPerFrame)
		try assertReadablePCM(at: recording.audioURL, expectedSamples: samples, frameCount: frames)
	}

	private func makeSamples(frameCount: Int) -> [Float] {
		(0..<(frameCount * SystemAudioRecoveryStore.channelCount)).map { index in
			Float(index % 257) / 257
		}
	}

	private func pcmData(_ samples: [Float]) -> Data {
		samples.withUnsafeBufferPointer { buffer in
			Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
		}
	}

	private func assertReadablePCM(
		at url: URL,
		expectedSamples: [Float],
		frameCount: Int,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws {
		let audioFile = try AVAudioFile(forReading: url)
		XCTAssertEqual(audioFile.fileFormat.sampleRate, SystemAudioRecoveryStore.sampleRate, file: file, line: line)
		XCTAssertEqual(Int(audioFile.fileFormat.channelCount), SystemAudioRecoveryStore.channelCount, file: file, line: line)
		XCTAssertEqual(Int(audioFile.length), frameCount, file: file, line: line)
		let buffer = try XCTUnwrap(
			AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat,
				frameCapacity: AVAudioFrameCount(frameCount)
			),
			file: file,
			line: line
		)
		try audioFile.read(into: buffer)
		XCTAssertEqual(Int(buffer.frameLength), frameCount, file: file, line: line)
		for channel in 0..<SystemAudioRecoveryStore.channelCount {
			let channelData = try XCTUnwrap(buffer.floatChannelData?[channel], file: file, line: line)
			for frame in 0..<frameCount {
				XCTAssertEqual(
					channelData[frame],
					expectedSamples[frame * SystemAudioRecoveryStore.channelCount + channel],
					accuracy: 0.000_001,
					file: file,
					line: line
				)
			}
		}
	}
}

import AVFoundation
import Darwin
import Foundation
import HexCore

/// A recoverable system-audio recording whose CAF file is itself the authoritative PCM store.
struct RecoveredSystemAudioRecording: Equatable, Sendable {
	let captureID: UUID
	let parentRecordingSessionID: UUID
	let createdAt: Date
	let audioURL: URL
	let duration: TimeInterval
}

/// Owns one open CAF file for the lifetime of a system-audio capture.
///
/// The CAF data chunk is created with an unknown length, which is valid while it is the final
/// chunk in the file. Each ScreenCaptureKit buffer is appended directly and synchronized before
/// the callback returns. On an ordinary stop (or the next launch), only the length field is
/// repaired and the same file is moved into the Recordings directory.
final class SystemAudioRecoverySession: @unchecked Sendable {
	let captureID: UUID
	let parentRecordingSessionID: UUID
	let createdAt: Date

	private let lock = NSLock()
	private let store: SystemAudioRecoveryStore
	private let activeURL: URL
	private var handle: FileHandle?

	fileprivate init(
		captureID: UUID,
		parentRecordingSessionID: UUID,
		createdAt: Date,
		store: SystemAudioRecoveryStore,
		activeURL: URL,
		handle: FileHandle
	) {
		self.captureID = captureID
		self.parentRecordingSessionID = parentRecordingSessionID
		self.createdAt = createdAt
		self.store = store
		self.activeURL = activeURL
		self.handle = handle
	}

	func appendInterleavedPCM(_ data: Data, frameCount: Int) throws {
		guard frameCount > 0 else { return }
		guard data.count == frameCount * SystemAudioRecoveryStore.bytesPerFrame else {
			throw SystemAudioRecoveryStore.Error.invalidPCMBuffer
		}

		lock.lock()
		defer { lock.unlock() }
		guard let handle else { throw SystemAudioRecoveryStore.Error.writeAfterSeal }
		try handle.write(contentsOf: data)
		// The callback does not acknowledge the buffer until its bytes have crossed the
		// FileHandle durability boundary. A hard stop may lose the device's own volatile cache,
		// but cannot invalidate the already-synchronized prefix of this recording.
		try handle.synchronize()
	}

	func finalize() throws -> RecoveredSystemAudioRecording? {
		lock.lock()
		defer { lock.unlock() }
		if let handle {
			try handle.synchronize()
			try handle.close()
			self.handle = nil
		}
		return try store.finalizeActiveRecording(
			at: activeURL,
			metadata: .init(
				captureID: captureID,
				parentRecordingSessionID: parentRecordingSessionID,
				createdAt: createdAt
			)
		)
	}

	func abandonForRecovery() {
		lock.lock()
		defer { lock.unlock() }
		try? handle?.synchronize()
		try? handle?.close()
		handle = nil
	}

	deinit {
		abandonForRecovery()
	}
}

/// Creates, finalizes, and rediscovers authoritative system-audio CAF files.
final class SystemAudioRecoveryStore: @unchecked Sendable {
	enum Error: LocalizedError {
		case couldNotCreateFile
		case invalidPCMBuffer
		case invalidRecording
		case writeAfterSeal

		var errorDescription: String? {
			switch self {
			case .couldNotCreateFile:
				"Could not create the system audio recovery file."
			case .invalidPCMBuffer:
				"System audio arrived in an unexpected PCM layout."
			case .invalidRecording:
				"The system audio recovery file is invalid."
			case .writeAfterSeal:
				"The system audio recovery file was already finalized."
			}
		}
	}

	fileprivate struct Metadata: Hashable {
		let captureID: UUID
		let parentRecordingSessionID: UUID
		let createdAt: Date
	}

	static let sampleRate = 48_000.0
	static let channelCount = 2
	static let bytesPerSample = MemoryLayout<Float>.size
	static let bytesPerFrame = channelCount * bytesPerSample

	private static let cafHeaderSize: UInt64 = 68
	private static let dataChunkSizeOffset: UInt64 = 56
	private static let filenamePrefix = "system__"
	private static let activeSuffix = ".caf.partial"
	private static let finalSuffix = ".caf"
	private static let logger = HexLog.recording

	private let fileManager: FileManager
	private let storageRoot: URL

	init(
		storageRoot: URL? = nil,
		fileManager: FileManager = .default
	) {
		self.fileManager = fileManager
		if let storageRoot {
			self.storageRoot = storageRoot
		} else if let applicationSupport = try? URL.hexApplicationSupport {
			self.storageRoot = applicationSupport
		} else {
			Self.logger.error("Falling back to the temporary directory for durable system audio storage")
			self.storageRoot = fileManager.temporaryDirectory
				.appendingPathComponent("io.github.blackforestboi.Octo", isDirectory: true)
		}
	}

	func begin(
		parentRecordingSessionID: UUID,
		createdAt: Date = Date()
	) throws -> SystemAudioRecoverySession {
		try createDirectories()
		let metadata = Metadata(
			captureID: UUID(),
			parentRecordingSessionID: parentRecordingSessionID,
			createdAt: createdAt
		)
		let url = activeURL(for: metadata)
		guard fileManager.createFile(atPath: url.path, contents: Self.cafHeader(dataByteCount: nil)) else {
			throw Error.couldNotCreateFile
		}
		let handle = try FileHandle(forWritingTo: url)
		try handle.seekToEnd()
		try handle.synchronize()
		synchronizeDirectory(at: activeDirectory)
		return SystemAudioRecoverySession(
			captureID: metadata.captureID,
			parentRecordingSessionID: metadata.parentRecordingSessionID,
			createdAt: metadata.createdAt,
			store: self,
			activeURL: url,
			handle: handle
		)
	}

	func recoverInterruptedRecordings() -> [RecoveredSystemAudioRecording] {
		do {
			try createDirectories()
			let activeFiles = try recordingFiles(in: activeDirectory, suffix: Self.activeSuffix)
			for url in activeFiles {
				guard let metadata = metadata(for: url, suffix: Self.activeSuffix) else { continue }
				do {
					_ = try finalizeActiveRecording(at: url, metadata: metadata)
				} catch {
					Self.logger.error("Could not recover interrupted system audio: \(error.localizedDescription, privacy: .private)")
				}
			}

			return try recordingFiles(in: recordingsDirectory, suffix: Self.finalSuffix).compactMap { url in
				guard let metadata = metadata(for: url, suffix: Self.finalSuffix) else { return nil }
				do {
					return try recoveredRecording(at: url, metadata: metadata)
				} catch {
					Self.logger.error("Could not inspect recovered system audio: \(error.localizedDescription, privacy: .private)")
					return nil
				}
			}
		} catch {
			Self.logger.error("Could not scan interrupted system audio: \(error.localizedDescription, privacy: .private)")
			return []
		}
	}

	fileprivate func finalizeActiveRecording(
		at activeURL: URL,
		metadata: Metadata
	) throws -> RecoveredSystemAudioRecording? {
		let frameCount = try repairCAF(at: activeURL)
		guard frameCount > 0 else {
			try? fileManager.removeItem(at: activeURL)
			return nil
		}

		let finalURL = finalURL(for: metadata)
		if fileManager.fileExists(atPath: finalURL.path) {
			// An atomic move cannot create two copies. This path is only expected after a
			// previous finalize completed; prefer the already-published recording and leave
			// any unexpected second file untouched for manual recovery.
			return try recoveredRecording(at: finalURL, metadata: metadata)
		}
		try fileManager.moveItem(at: activeURL, to: finalURL)
		synchronizeDirectory(at: activeDirectory)
		synchronizeDirectory(at: recordingsDirectory)
		return RecoveredSystemAudioRecording(
			captureID: metadata.captureID,
			parentRecordingSessionID: metadata.parentRecordingSessionID,
			createdAt: metadata.createdAt,
			audioURL: finalURL,
			duration: Double(frameCount) / Self.sampleRate
		)
	}

	private func recoveredRecording(
		at url: URL,
		metadata: Metadata
	) throws -> RecoveredSystemAudioRecording? {
		let frameCount = try repairCAF(at: url)
		guard frameCount > 0 else { return nil }
		return RecoveredSystemAudioRecording(
			captureID: metadata.captureID,
			parentRecordingSessionID: metadata.parentRecordingSessionID,
			createdAt: metadata.createdAt,
			audioURL: url,
			duration: Double(frameCount) / Self.sampleRate
		)
	}

	private func repairCAF(at url: URL) throws -> Int64 {
		guard isRegularFile(url) else { throw Error.invalidRecording }
		let handle = try FileHandle(forUpdating: url)
		defer { try? handle.close() }
		try handle.seek(toOffset: 0)
		guard let header = try handle.read(upToCount: Int(Self.cafHeaderSize)),
			header.count == Self.cafHeaderSize,
			Self.isExpectedHeader(header)
		else { throw Error.invalidRecording }

		let fileSize = try handle.seekToEnd()
		guard fileSize >= Self.cafHeaderSize else { throw Error.invalidRecording }
		let payloadBytes = fileSize - Self.cafHeaderSize
		let alignedPayloadBytes = payloadBytes - (payloadBytes % UInt64(Self.bytesPerFrame))
		var repaired = false
		if alignedPayloadBytes != payloadBytes {
			try handle.truncate(atOffset: Self.cafHeaderSize + alignedPayloadBytes)
			repaired = true
		}
		let expectedDataChunkSize = Int64(alignedPayloadBytes + 4)
		if Self.bigEndianInt64(in: header, at: Int(Self.dataChunkSizeOffset)) != expectedDataChunkSize {
			try handle.seek(toOffset: Self.dataChunkSizeOffset)
			try handle.write(contentsOf: Self.bigEndianData(expectedDataChunkSize))
			repaired = true
		}
		if repaired {
			try handle.synchronize()
		}
		return Int64(alignedPayloadBytes / UInt64(Self.bytesPerFrame))
	}

	private func createDirectories() throws {
		try fileManager.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
		try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
	}

	private func recordingFiles(in directory: URL, suffix: String) throws -> [URL] {
		try fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
			options: [.skipsHiddenFiles]
		)
		.filter { $0.lastPathComponent.hasPrefix(Self.filenamePrefix) && $0.lastPathComponent.hasSuffix(suffix) }
		.filter(isRegularFile)
		.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	private func metadata(for url: URL, suffix: String) -> Metadata? {
		let name = url.lastPathComponent
		guard name.hasPrefix(Self.filenamePrefix), name.hasSuffix(suffix) else { return nil }
		let body = name.dropFirst(Self.filenamePrefix.count).dropLast(suffix.count)
		let fields = body.split(separator: "_", omittingEmptySubsequences: false)
		guard fields.count == 5 else { return nil }
		// UUID strings contain four hyphens but no underscores. The double underscores in
		// the filename therefore produce empty fields between the three metadata values.
		guard fields[1].isEmpty, fields[3].isEmpty,
			let parentID = UUID(uuidString: String(fields[0])),
			let captureID = UUID(uuidString: String(fields[2])),
			let milliseconds = Int64(fields[4])
		else { return nil }
		return Metadata(
			captureID: captureID,
			parentRecordingSessionID: parentID,
			createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
		)
	}

	private func activeURL(for metadata: Metadata) -> URL {
		activeDirectory.appendingPathComponent(filename(for: metadata, suffix: Self.activeSuffix))
	}

	private func finalURL(for metadata: Metadata) -> URL {
		recordingsDirectory.appendingPathComponent(filename(for: metadata, suffix: Self.finalSuffix))
	}

	private func filename(for metadata: Metadata, suffix: String) -> String {
		let milliseconds = Int64((metadata.createdAt.timeIntervalSince1970 * 1_000).rounded())
		return "\(Self.filenamePrefix)\(metadata.parentRecordingSessionID.uuidString)__\(metadata.captureID.uuidString)__\(milliseconds)\(suffix)"
	}

	private var activeDirectory: URL {
		storageRoot.appendingPathComponent("ActiveSystemAudio", isDirectory: true)
	}

	private var recordingsDirectory: URL {
		storageRoot.appendingPathComponent("Recordings", isDirectory: true)
	}

	private func isRegularFile(_ url: URL) -> Bool {
		guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
		return values.isRegularFile == true && values.isSymbolicLink != true
	}

	private func synchronizeDirectory(at url: URL) {
		let descriptor = Darwin.open(url.path, O_RDONLY)
		guard descriptor >= 0 else { return }
		defer { Darwin.close(descriptor) }
		_ = Darwin.fsync(descriptor)
	}

	private static func cafHeader(dataByteCount: Int64?) -> Data {
		var data = Data()
		data.appendBigEndian(UInt32(0x6361_6666)) // caff
		data.appendBigEndian(UInt16(1))
		data.appendBigEndian(UInt16(0))
		data.appendBigEndian(UInt32(0x6465_7363)) // desc
		data.appendBigEndian(Int64(32))
		data.appendBigEndian(sampleRate.bitPattern)
		data.appendBigEndian(UInt32(kAudioFormatLinearPCM))
		// CAF's LPCM flags deliberately differ from AudioStreamBasicDescription flags:
		// bit 1 means little-endian here (not big-endian). The appended Float bytes use
		// the Mac's native little-endian representation.
		data.appendBigEndian(UInt32((1 << 0) | (1 << 1)))
		data.appendBigEndian(UInt32(bytesPerFrame))
		data.appendBigEndian(UInt32(1))
		data.appendBigEndian(UInt32(channelCount))
		data.appendBigEndian(UInt32(bytesPerSample * 8))
		data.appendBigEndian(UInt32(0x6461_7461)) // data
		data.appendBigEndian(dataByteCount.map { $0 + 4 } ?? -1)
		data.appendBigEndian(UInt32(0)) // edit count
		return data
	}

	private static func isExpectedHeader(_ header: Data) -> Bool {
		let expected = cafHeader(dataByteCount: 0)
		return header.prefix(Int(dataChunkSizeOffset)) == expected.prefix(Int(dataChunkSizeOffset))
			&& header.suffix(from: Int(dataChunkSizeOffset + 8)) == expected.suffix(from: Int(dataChunkSizeOffset + 8))
	}

	private static func bigEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
		var bigEndian = value.bigEndian
		return withUnsafeBytes(of: &bigEndian) { Data($0) }
	}

	private static func bigEndianInt64(in data: Data, at offset: Int) -> Int64 {
		let value = data[offset..<(offset + MemoryLayout<UInt64>.size)].reduce(UInt64(0)) {
			($0 << 8) | UInt64($1)
		}
		return Int64(bitPattern: value)
	}
}

private extension Data {
	mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
		var bigEndian = value.bigEndian
		Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
	}
}

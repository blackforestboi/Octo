import Foundation
import HexCore

/// Owns the bounded PCM stream for the current recording take.
///
/// `AsyncStream` becomes terminal when its consumer is cancelled, so a stream cannot be
/// reused across pause/resume or separate Recording Sessions. Starting a take swaps in a fresh
/// stream before capture emits its first chunk while preserving buffering for the short interval
/// before the live-transcription effect subscribes.
final class CapturedAudioChunkRelay: @unchecked Sendable {
	typealias Stream = AsyncStream<CapturedAudioChunk>
	private static let bufferCapacity = 3_000

	private let lock = NSLock()
	private var takeGeneration: UUID?
	private var currentStream: Stream
	private var continuation: Stream.Continuation

	init() {
		let pair = Self.makeStream()
		currentStream = pair.stream
		continuation = pair.continuation
	}

	func beginTake(_ generation: UUID) {
		let pair = Self.makeStream()
		let previous: Stream.Continuation? = lock.withLock {
			guard takeGeneration != generation else { return nil }
			let previous = continuation
			takeGeneration = generation
			currentStream = pair.stream
			continuation = pair.continuation
			return previous
		}
		previous?.finish()
	}

	func stream() -> Stream {
		lock.withLock { currentStream }
	}

	/// Returns `true` when the active consumer fell behind the bounded stream.
	@discardableResult
	func yield(_ chunk: CapturedAudioChunk) -> Bool {
		let result = lock.withLock { continuation.yield(chunk) }
		if case .dropped = result { return true }
		return false
	}

	private static func makeStream() -> (
		stream: Stream,
		continuation: Stream.Continuation
	) {
		Stream.makeStream(bufferingPolicy: .bufferingNewest(bufferCapacity))
	}
}

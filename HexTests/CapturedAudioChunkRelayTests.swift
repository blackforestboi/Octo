import HexCore
import XCTest

@testable import Octo

final class CapturedAudioChunkRelayTests: XCTestCase {
	func testBeginningANewTakeReplacesTerminatedChunkStream() async {
		let relay = CapturedAudioChunkRelay()
		let firstTake = UUID()
		let secondTake = UUID()

		relay.beginTake(firstTake)
		let firstConsumer = Task {
			for await _ in relay.stream() {}
		}
		relay.yield(chunk(take: firstTake, sample: 1))
		await Task.yield()
		firstConsumer.cancel()
		await firstConsumer.value

		relay.beginTake(secondTake)
		var secondIterator = relay.stream().makeAsyncIterator()
		relay.yield(chunk(take: secondTake, sample: 2))
		let secondChunk = await secondIterator.next()

		XCTAssertEqual(secondChunk?.takeGeneration, secondTake)
		XCTAssertEqual(secondChunk?.samples, [2])
	}

	private func chunk(take: UUID, sample: Float) -> CapturedAudioChunk {
		.init(
			source: .microphone,
			takeGeneration: take,
			sequence: 0,
			startSample: 0,
			samples: [sample]
		)
	}
}

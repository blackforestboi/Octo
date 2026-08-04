import XCTest

@testable import Octo

#if canImport(FluidAudio)
private actor ModelLoadProbe {
	private var continuations: [CheckedContinuation<Void, Never>] = []
	private(set) var count = 0
	private var isReleased = false

	func load() async -> Int {
		count += 1
		if !isReleased {
			await withCheckedContinuation { continuation in
				continuations.append(continuation)
			}
		}
		return 42
	}

	func release() {
		isReleased = true
		let pending = continuations
		continuations.removeAll()
		pending.forEach { $0.resume() }
	}
}

final class ParakeetModelLoadTests: XCTestCase {
	func testConcurrentRequestsShareOneLoadAndReuseItsValue() async throws {
		let cache = CoalescingAsyncCache<String, Int>()
		let probe = ModelLoadProbe()
		let requests = (0..<8).map { _ in
			Task {
				try await cache.value(for: "parakeet-v3") {
					await probe.load()
				}
			}
		}

		while await probe.count == 0 {
			await Task.yield()
		}
		try await Task.sleep(nanoseconds: 20_000_000)
		let inFlightLoadCount = await probe.count
		await probe.release()

		var values: [Int] = []
		for request in requests {
			values.append(try await request.value)
		}

		XCTAssertEqual(inFlightLoadCount, 1)
		XCTAssertEqual(values, Array(repeating: 42, count: requests.count))

		let cachedValue = try await cache.value(for: "parakeet-v3") {
			await probe.load()
		}
		let finalLoadCount = await probe.count
		XCTAssertEqual(cachedValue, 42)
		XCTAssertEqual(finalLoadCount, 1)
	}
}
#endif

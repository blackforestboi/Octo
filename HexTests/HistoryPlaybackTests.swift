import ComposableArchitecture
import Foundation
import AVFoundation
import HexCore
import XCTest

@testable import Octo

@MainActor
final class HistoryPlaybackTests: XCTestCase {
  func testStoppingPlaybackCompletesWaitersExactlyOnce() async {
    let controller = AudioPlayerController()
    let waiter = Task {
      await controller.waitForPlaybackToFinish()
    }

    await Task.yield()
    controller.stop()
    controller.stop()

    await waiter.value
    await controller.waitForPlaybackToFinish()
  }

  func testStalePlaybackFinishedDoesNotStopCurrentPlayback() async {
    let transcriptID = UUID()
    let playbackID = UUID()
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(value: .init()),
        playingTranscriptID: transcriptID,
        playbackID: playbackID
      )
    ) {
      HistoryFeature()
    }

    await store.send(.playbackFinished(UUID()))

    XCTAssertEqual(store.state.playingTranscriptID, transcriptID)
    XCTAssertEqual(store.state.playbackID, playbackID)
  }

  func testTogglingCurrentPlaybackPausesAndResumes() async throws {
    let transcriptID = UUID()
    let playbackID = UUID()
    let audioURL = try makeTestAudioURL()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let controller = AudioPlayerController()
    let duration = try controller.play(url: audioURL)
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(value: .init()),
        playingTranscriptID: transcriptID,
        playbackID: playbackID,
        audioPlayerController: controller,
        playbackProgress: controller.currentTime,
        playbackDuration: duration
      )
    ) {
      HistoryFeature()
    }

    await store.send(.playTranscript(transcriptID)) {
      $0.isPlaybackPaused = true
    }
    await store.send(.playTranscript(transcriptID)) {
      $0.isPlaybackPaused = false
    }

    await store.send(.stopPlayback) {
      $0.playingTranscriptID = nil
      $0.playbackID = nil
      $0.audioPlayerController = nil
      $0.playbackProgress = 0
      $0.playbackDuration = 0
      $0.isPlaybackPaused = false
    }
  }

  func testSeekingFromIdleStartsPlaybackAtRequestedTime() async throws {
    let transcriptID = UUID()
    let audioURL = try makeTestAudioURL()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let transcript = Transcript(
      id: transcriptID,
      timestamp: Date(),
      text: "Test",
      audioPath: audioURL,
      duration: 0.1
    )
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(value: TranscriptionHistory(history: [transcript]))
      )
    ) {
      HistoryFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.seekTranscript(transcriptID, 0.05))
    XCTAssertEqual(store.state.playingTranscriptID, transcriptID)
    XCTAssertGreaterThan(store.state.playbackDuration, 0)
    XCTAssertEqual(store.state.playbackProgress, 0.05, accuracy: 0.02)
    XCTAssertFalse(store.state.isPlaybackPaused)

    await store.send(.stopPlayback)
    XCTAssertNil(store.state.playingTranscriptID)
    XCTAssertNil(store.state.playbackID)
  }

  func testMatchingPlaybackCompletionResetsPlaybackState() async {
    let playbackID = UUID()
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(value: .init()),
        playingTranscriptID: UUID(),
        playbackID: playbackID,
        audioPlayerController: AudioPlayerController(),
        playbackProgress: 0.5,
        playbackDuration: 1,
        isPlaybackPaused: true
      )
    ) {
      HistoryFeature()
    }

    await store.send(.playbackFinished(playbackID)) {
      $0.playingTranscriptID = nil
      $0.playbackID = nil
      $0.audioPlayerController = nil
      $0.playbackProgress = 0
      $0.playbackDuration = 0
      $0.isPlaybackPaused = false
    }
  }
}

private func makeTestAudioURL() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("hex-history-playback-\(UUID().uuidString).caf")
  let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
  buffer.frameLength = 44_100
  try file.write(from: buffer)
  return url
}

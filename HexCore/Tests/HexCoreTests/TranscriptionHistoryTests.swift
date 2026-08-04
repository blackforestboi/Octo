import Foundation
import Testing
@testable import HexCore

struct TranscriptionHistoryTests {
	@Test
	func legacyTranscriptDecodesWithoutTimestampedSections() throws {
		let legacyData = Data(
			#"{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"text":"legacy transcript","audioPath":"file:///legacy.wav","duration":1}"#.utf8
		)

		let transcript = try JSONDecoder().decode(Transcript.self, from: legacyData)

		#expect(transcript.timestampedSections == nil)
		#expect(transcript.audioChannels == nil)
		#expect(transcript.liveTranscriptCheckpoint == nil)
		#expect(transcript.sessionSpeakers == nil)
	}

	@Test
	func liveCheckpointAndStableSessionSpeakersRoundTrip() throws {
		let takeGeneration = UUID()
		let profileID = UUID()
		let speaker = SessionSpeaker(
			fallbackLabel: "Speaker A",
			profileID: profileID,
			lastKnownProfileName: "Oliver"
		)
		let checkpoint = LiveTranscriptCheckpoint(
			sources: [
				.microphone: .init(committedThroughSample: 32_000, observedThroughSample: 48_000),
				.systemAudio: .init(committedThroughSample: 31_000, observedThroughSample: 47_000),
			],
			globalDisplayThroughSample: 31_000,
			lastCommitSequence: 3,
			takeGeneration: takeGeneration,
			drainState: .drainingForPause
		)
		let section = TimestampedTranscriptSection(
			text: "Durable text.",
			startTime: 0,
			endTime: 2,
			audioSource: .microphone,
			speakerName: "Speaker A",
			sessionSpeakerID: speaker.id,
			commitSequence: 3,
			fragmentKind: .speech
		)
		let transcript = Transcript(
			timestamp: .now,
			text: section.text,
			audioPath: URL(fileURLWithPath: "/live.wav"),
			duration: 3,
			timestampedSections: [section],
			sessionSpeakers: [speaker],
			liveTranscriptCheckpoint: checkpoint,
			liveSpeakerIdentificationEnabled: true,
			liveSpeakerDiarizationMode: .moreSpeakersTen
		)

		let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))

		#expect(decoded.timestampedSections == [section])
		#expect(decoded.sessionSpeakers == [speaker])
		#expect(decoded.liveTranscriptCheckpoint == checkpoint)
		#expect(decoded.liveSpeakerIdentificationEnabled == true)
		#expect(decoded.liveSpeakerDiarizationMode == .moreSpeakersTen)
	}

	@Test
	func audioChannelsRoundTripSeparatelyWithTheirTimelineLabels() throws {
		let microphone = TranscriptAudioChannel(
			source: .microphone,
			audioPath: URL(fileURLWithPath: "/mic.wav"),
			duration: 4,
			text: "Hello",
			timestampedSections: [.init(text: "Hello", startTime: 0, endTime: 1, audioSource: .microphone)]
		)
		let systemAudio = TranscriptAudioChannel(
			source: .systemAudio,
			audioPath: URL(fileURLWithPath: "/system.m4a"),
			duration: 4,
			text: "Welcome",
			timestampedSections: [.init(text: "Welcome", startTime: 0.5, endTime: 1.5, audioSource: .systemAudio)]
		)
		let transcript = Transcript(
			timestamp: .now,
			text: "Hello Welcome",
			audioPath: microphone.audioPath,
			duration: 4,
			audioChannels: [microphone, systemAudio]
		)

		let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))

		#expect(decoded.audioChannels == [microphone, systemAudio])
		#expect(decoded.audioChannels?[0].timestampedSections?.first?.displayLabel == "Microphone")
		#expect(decoded.audioChannels?[1].timestampedSections?.first?.displayLabel == "System Audio")
	}

	@Test
	func recordingSessionMetadataRoundTripsAndLegacyFilesRemainCompatible() throws {
		let sessionID = UUID()
		let transcript = Transcript(
			timestamp: .now,
			text: "Session take",
			audioPath: URL(fileURLWithPath: "/session.wav"),
			duration: 2,
			recordingSessionID: sessionID,
			recordingSessionTitle: "Recording: Aug 3, 2026 at 13:00"
		)

		let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))

		#expect(decoded.recordingSessionID == sessionID)
		#expect(decoded.recordingSessionTitle == "Recording: Aug 3, 2026 at 13:00")
	}

	@Test
	func latestPasteableTranscriptUsesNewestTimestamp() {
		let oldTranscript = Transcript(
			timestamp: Date(timeIntervalSince1970: 1),
			text: "old transcript",
			audioPath: URL(fileURLWithPath: "/old.wav"),
			duration: 1
		)
		let newestTranscript = Transcript(
			timestamp: Date(timeIntervalSince1970: 3),
			text: "new transcript",
			audioPath: URL(fileURLWithPath: "/new.wav"),
			duration: 1
		)
		let recoveredTranscript = Transcript(
			timestamp: Date(timeIntervalSince1970: 4),
			text: "recovered audio",
			audioPath: URL(fileURLWithPath: "/recovered.wav"),
			duration: 1,
			recoverySessionID: UUID()
		)

		let history = TranscriptionHistory(history: [oldTranscript, recoveredTranscript, newestTranscript])

		#expect(history.latestPasteableTranscriptText == "new transcript")
	}
}

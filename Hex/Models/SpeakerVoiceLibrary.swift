import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

extension SharedReaderKey
	where Self == FileStorageKey<SpeakerVoiceLibrary>.Default
{
	static var speakerVoiceLibrary: Self {
		Self[
			.fileStorage(.speakerVoiceLibraryURL),
			default: .init()
		]
	}
}

extension URL {
	static var speakerVoiceLibraryURL: URL {
		URL.hexStoredFileURL(named: "speaker_voice_library.json")
	}
}

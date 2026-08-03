import XCTest
@testable import HexCore

final class HexSettingsMigrationTests: XCTestCase {
	func testV1FixtureMigratesToCurrentDefaults() throws {
		let data = try loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.recordingAudioBehavior, .pauseMedia, "Legacy pauseMediaOnRecord bool should map to pauseMedia behavior")
		XCTAssertEqual(decoded.soundEffectsEnabled, false)
		XCTAssertEqual(decoded.soundEffectsVolume, HexSettings.baseSoundEffectsVolume)
		XCTAssertEqual(decoded.openOnLogin, true)
		XCTAssertEqual(decoded.showDockIcon, false)
		XCTAssertEqual(decoded.indicatorSize, .regular)
		XCTAssertEqual(decoded.indicatorLocation, .topCenter)
		XCTAssertEqual(decoded.selectedModel, "whisper-large-v3")
		XCTAssertEqual(decoded.useClipboardPaste, false)
		XCTAssertEqual(decoded.preventSystemSleep, true)
		XCTAssertEqual(decoded.minimumKeyTime, 0.25)
		XCTAssertEqual(decoded.stopDelayMilliseconds, 0)
		XCTAssertEqual(decoded.longRecordingConfirmationThresholdMinutes, 1)
		XCTAssertEqual(decoded.copyToClipboard, true)
		XCTAssertTrue(decoded.superFastModeEnabled)
		XCTAssertEqual(decoded.useDoubleTapOnly, true)
		XCTAssertTrue(decoded.allowLongPressForOnDemand)
		XCTAssertEqual(decoded.doubleTapLockEnabled, true)
		XCTAssertEqual(decoded.outputLanguage, "en")
		XCTAssertEqual(decoded.selectedMicrophoneID, "builtin:mic")
		XCTAssertEqual(decoded.saveTranscriptionHistory, false)
		XCTAssertEqual(decoded.maxHistoryEntries, 10)
		XCTAssertEqual(decoded.hasCompletedModelBootstrap, true)
		XCTAssertEqual(decoded.hasCompletedStorageMigration, true)
		XCTAssertFalse(decoded.lowercaseTranscripts)
		XCTAssertFalse(decoded.removePunctuation)
		XCTAssertEqual(decoded.refinementMode, .raw)
		XCTAssertTrue(decoded.refinementEnabled)
		XCTAssertEqual(decoded.refinementProvider, .apple)
		XCTAssertEqual(decoded.agentHandoffProvider, .codexCLI)
		XCTAssertFalse(decoded.agentHandoffEnabled)
		XCTAssertNil(decoded.agentHandoffModelID)
		XCTAssertEqual(decoded.agentHandoffReasoningEffort, .medium)
		XCTAssertTrue(decoded.hasCompletedRefinementProviderDetection)
		XCTAssertEqual(decoded.refinementInstructions, HexSettings.defaultRefinementInstructions)
		XCTAssertEqual(decoded.rewritePrompts.count, 1)
		XCTAssertEqual(decoded.rewritePrompts[0].instructions, HexSettings.defaultRefinementInstructions)
			XCTAssertNil(decoded.openRouterModelID)
			XCTAssertNil(decoded.screenAwareOpenRouterModelID)
			XCTAssertEqual(decoded.screenAwareInputSource, .localOCR)
		XCTAssertTrue(decoded.includeSelectedTextInRefinement)
		XCTAssertFalse(decoded.speakerIdentificationEnabled)
		XCTAssertEqual(decoded.speakerDiarizationProvider, .fluidAudio)
	}

	func testEncodeDecodeRoundTripPreservesDefaults() throws {
		let settings = HexSettings()
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded, settings)
	}

	func testLegacyCLIRefinementSettingsMigrateToMatchingHandoffConfiguration() throws {
		let settings = HexSettings(refinementProvider: .claudeCLI, claudeCLIModelID: "sonnet")
		let encoded = try JSONEncoder().encode(settings)
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "agentHandoffProvider")
		object.removeValue(forKey: "agentHandoffModelID")
		let legacyData = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(HexSettings.self, from: legacyData)

		XCTAssertEqual(decoded.agentHandoffProvider, .claudeCLI)
		XCTAssertEqual(decoded.agentHandoffModelID, "sonnet")
	}

	func testNewSettingsEnableSuperFastModeByDefault() {
		XCTAssertTrue(HexSettings().superFastModeEnabled)
		XCTAssertEqual(HexSettings().stopDelayMilliseconds, 0)
		XCTAssertEqual(HexSettings().longRecordingConfirmationThresholdMinutes, 1)
	}

	func testLongPressOnDemandIsEnabledByDefault() {
		XCTAssertTrue(HexSettings().allowLongPressForOnDemand)
	}

	func testNewSettingsDisableScreenAwareDictationByDefault() {
		XCTAssertFalse(HexSettings().screenAwareDictationEnabled)
	}

	func testIndicatorPreferencesRoundTrip() throws {
		let settings = HexSettings(indicatorSize: .large, indicatorLocation: .bottomTrailing)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))

		XCTAssertEqual(decoded.indicatorSize, .large)
		XCTAssertEqual(decoded.indicatorLocation, .bottomTrailing)
	}

	func testNewSettingsCheckForAnAvailableSubscriptionProvider() {
		XCTAssertFalse(HexSettings().hasCompletedRefinementProviderDetection)
	}

	func testNewSettingsDefaultToDoubleTapOnly() {
		XCTAssertTrue(HexSettings().useDoubleTapOnly)
	}

	func testInitNormalizesDoubleTapOnlyWhenLockDisabled() {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(settings.doubleTapLockEnabled)
	}

	func testDecodeNormalizesDoubleTapOnlyWhenLockDisabled() throws {
		let payload = "{\"useDoubleTapOnly\":true,\"doubleTapLockEnabled\":false}"
		guard let data = payload.data(using: .utf8) else {
			XCTFail("Failed to encode JSON payload")
			return
		}

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertFalse(decoded.doubleTapLockEnabled)
	}

	func testRefinementInstructionsRoundTrip() throws {
		let settings = HexSettings(
			refinementInstructions: "Return exactly three points.",
			screenAwareOpenRouterModelID: "anthropic/claude-sonnet-4",
			screenAwareInputSource: .image,
			includeSelectedTextInRefinement: false
		)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))

		XCTAssertEqual(decoded.refinementInstructions, "Return exactly three points.")
		XCTAssertEqual(decoded.rewritePrompts.count, 1)
		XCTAssertEqual(decoded.rewritePrompts[0].instructions, "Return exactly three points.")
		XCTAssertEqual(decoded.screenAwareOpenRouterModelID, "anthropic/claude-sonnet-4")
		XCTAssertEqual(decoded.screenAwareInputSource, .image)
		XCTAssertFalse(decoded.includeSelectedTextInRefinement)
	}

	func testOpenRouterShortlistRoundTripsAndDeduplicatesModelIDs() throws {
		let settings = HexSettings(
			openRouterShortlistedModelIDs: ["fast", "thorough", "fast"]
		)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))

		XCTAssertEqual(settings.openRouterShortlistedModelIDs, ["fast", "thorough"])
		XCTAssertEqual(decoded.openRouterShortlistedModelIDs, ["fast", "thorough"])
		XCTAssertEqual(
			try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8)).openRouterShortlistedModelIDs,
			[]
		)
	}

	func testLegacyInstructionsMigrateToTheDefaultRewritePrompt() throws {
		let decoded = try JSONDecoder().decode(
			HexSettings.self,
			from: Data("{\"refinementInstructions\":\"Keep technical terms.\"}".utf8)
		)

		XCTAssertEqual(decoded.rewritePrompts.map(\.name), [HexSettings.defaultRewritePromptName])
		XCTAssertEqual(decoded.rewritePrompts.map(\.instructions), ["Keep technical terms."])
	}

	func testEncodeDecodeRoundTripPreservesNormalizedDoubleTapValues() throws {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertEqual(decoded, settings)
	}

	private func loadFixture(named name: String) throws -> Data {
		guard let url = Bundle.module.url(
			forResource: name,
			withExtension: "json",
			subdirectory: "Fixtures/HexSettings"
		) else {
			XCTFail("Missing fixture \(name).json")
			throw NSError(domain: "Fixture", code: 0)
		}
		return try Data(contentsOf: url)
	}
}

import ComposableArchitecture
import HexCore
import XCTest

@testable import Octo

@MainActor
final class ModelDownloadFeatureTests: XCTestCase {
  func testPersistedModelDisplaysWhileAvailabilityLoads() {
    let state = makeState(selectedModel: ParakeetModel.englishV2.identifier)

    XCTAssertTrue(state.availableModels.isEmpty)
    XCTAssertEqual(state.selectedModelNameForDisplay, ParakeetModel.englishV2.identifier)
  }

  func testSuggestedParakeetFollowsOutputLanguage() {
    var state = makeState(selectedModel: "")
    XCTAssertEqual(state.preferredParakeetIdentifier, ParakeetModel.englishV2.identifier)

    state.$hexSettings.withLock { $0.outputLanguage = "en" }
    XCTAssertEqual(state.preferredParakeetIdentifier, ParakeetModel.englishV2.identifier)

    state.$hexSettings.withLock { $0.outputLanguage = "fr" }
    XCTAssertEqual(state.preferredParakeetIdentifier, ParakeetModel.multilingualV3.identifier)
  }

  func testFailedModelRefreshPreservesInstalledSelection() async {
    var state = makeState(selectedModel: "installed-model")
    state.availableModels = [ModelInfo(name: "installed-model", isDownloaded: true)]

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    } withDependencies: {
      $0.transcription.getRecommendedModels = { throw TestError() }
      $0.transcription.getAvailableModels = { [] }
    }

    await store.send(.fetchModels) {
      $0.isLoadingModels = true
    }
    await store.receive(\.modelsLoadFailed) {
      $0.isLoadingModels = false
    }

    XCTAssertEqual(store.state.hexSettings.selectedModel, "installed-model")
    XCTAssertTrue(store.state.availableModels[id: "installed-model"]?.isDownloaded == true)
  }

  func testStaleDownloadUpdatesAreIgnored() async {
    let currentID = UUID()
    var state = makeState(selectedModel: "installed-model")
    state.isDownloading = true
    state.downloadingModelName = "new-model"
    state.activeDownloadID = currentID
    state.downloadProgress = 0.25

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }

    await store.send(.downloadProgress(id: UUID(), update: .init(phase: .downloading, progress: 0.9)))
    await store.send(.downloadCompleted(id: UUID(), result: .success("other-model")))

    XCTAssertEqual(store.state.activeDownloadID, currentID)
    XCTAssertEqual(store.state.downloadProgress, 0.25)
    XCTAssertEqual(store.state.hexSettings.selectedModel, "installed-model")
  }

  func testActivationKeepsModelUnavailableUntilMatchingCompletion() async {
    let downloadID = UUID()
    var state = makeState(selectedModel: "new-model")
    state.availableModels = [ModelInfo(name: "new-model", isDownloaded: false)]
    state.isDownloading = true
    state.downloadingModelName = "new-model"
    state.activeDownloadID = downloadID
    state.downloadPhase = .downloading
    state.$modelBootstrapState.withLock {
      $0.modelIdentifier = "new-model"
	  $0.modelDisplayName = "New Model"
      $0.isModelReady = false
      $0.preparationPhase = .downloading
      $0.progress = 0.9
    }

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }

    await store.send(.downloadProgress(
      id: downloadID,
      update: .init(phase: .activating, progress: 1)
    )) {
      $0.downloadProgress = 1
      $0.downloadPhase = .activating
      $0.$modelBootstrapState.withLock {
        $0.isModelReady = false
        $0.preparationPhase = .activating
        $0.progress = 1
      }
    }

    XCTAssertFalse(store.state.modelBootstrapState.isModelReady)

    await store.send(.downloadCompleted(id: downloadID, result: .success("new-model"))) {
      $0.availableModels[id: "new-model"]?.isDownloaded = true
      $0.isDownloading = false
      $0.downloadingModelName = nil
      $0.activeDownloadID = nil
      $0.downloadProgress = 0
      $0.downloadPhase = nil
      $0.$hexSettings.withLock { $0.hasCompletedModelBootstrap = true }
      $0.$modelBootstrapState.withLock {
        $0.isModelReady = true
        $0.preparationPhase = nil
        $0.progress = 1
      }
    }
  }

  func testModelsLoadedNeverClearsSelectionWhenNothingDetected() async {
    // Regression: 0.8.0 cleared selectedModel to "" when an availability scan
    // came back empty (e.g. after FluidAudio moved its cache directory),
    // permanently breaking transcription with no visible error.
    var state = makeState(selectedModel: ParakeetModel.englishV2.identifier)
    state.availableModels = []

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }
    store.exhaustivity = .off

    await store.send(.modelsLoaded(recommended: "", available: []))

    XCTAssertEqual(store.state.hexSettings.selectedModel, ParakeetModel.englishV2.identifier)
  }

  func testSelectedModelIsDownloadedMatchesPatterns() {
    var state = makeState(selectedModel: "distil*large-v3")
    state.availableModels = [
      ModelInfo(name: "distil-whisper_distil-large-v3", isDownloaded: true)
    ]
    XCTAssertTrue(state.selectedModelIsDownloaded)

    state.availableModels = [
      ModelInfo(name: "distil-whisper_distil-large-v3", isDownloaded: false)
    ]
    XCTAssertFalse(state.selectedModelIsDownloaded)

    var emptyState = makeState(selectedModel: "")
    emptyState.availableModels = [ModelInfo(name: "some-model", isDownloaded: true)]
    XCTAssertFalse(emptyState.selectedModelIsDownloaded)
  }

  func testDeletingAnotherModelDoesNotChangeSelection() async {
    var state = makeState(selectedModel: "selected-model")
    state.availableModels = [
      ModelInfo(name: "selected-model", isDownloaded: true),
      ModelInfo(name: "other-model", isDownloaded: true),
    ]

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    } withDependencies: {
      $0.transcription.deleteModel = { _ in
        try await Task.sleep(for: .seconds(60))
      }
    }

    await store.send(.deleteModel("other-model"))
    XCTAssertEqual(store.state.hexSettings.selectedModel, "selected-model")
    await store.skipInFlightEffects()
  }

  private func makeState(selectedModel: String) -> ModelDownloadFeature.State {
    var settings = HexSettings()
    settings.selectedModel = selectedModel
    settings.hasCompletedModelBootstrap = true
    return ModelDownloadFeature.State(
      hexSettings: Shared(value: settings),
      modelBootstrapState: Shared(value: .init(isModelReady: true))
    )
  }
}

private struct TestError: Error {}

import Foundation
import XCTest

@testable import Octo

final class AgentHandoffClientTests: XCTestCase {
	func testLaunchFailureIncludesDiagnostic() {
		let error = AgentHandoffError.launchFailed(
			"Codex planner",
			diagnostic: "Codex exited with status 1. Sign in required."
		)

		XCTAssertEqual(
			error.errorDescription,
			"Codex planner could not start the agent handoff. Codex exited with status 1. Sign in required."
		)
	}

	func testCodexThreadDestinationUsesTheDesktopThreadRoute() {
		let id = "528b9ff2-d685-4c1a-b2d8-76d6a1661de3"

		let url = AgentHandoffThreadDestination.codexURL(for: id)

		XCTAssertEqual(url?.absoluteString, "codex://threads/\(id)")
	}

	func testCodexThreadDestinationRejectsMalformedThreadIDs() {
		XCTAssertNil(AgentHandoffThreadDestination.codexURL(for: "not-a-thread"))
	}

	func testHandoffTaskIsOpenableOnlyWhenDoneWithANativeThread() {
		let task = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Update menu bar",
			state: .completed,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: ""
		)
		let legacyTask = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Legacy handoff",
			state: .pending,
			thread: nil,
			handoff: ""
		)

		XCTAssertTrue(task.isOpenable)
		XCTAssertFalse(legacyTask.isOpenable)
	}

	func testHandoffTaskIsNotOpenableBeforeItIsDone() {
		let thread = AgentHandoffThread.codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3")

		for state in [AgentHandoffTask.Status.pending, .threadCreated, .registered, .running, .failed] {
			let task = AgentHandoffTask(
				id: UUID(),
				createdAt: .now,
				provider: .codex,
				title: "Update menu bar",
				state: state,
				thread: thread,
				handoff: ""
			)

			XCTAssertFalse(task.isOpenable, "Unexpectedly openable in state \(state)")
		}
	}

	func testHandoffTaskExposesLifecycleStateForMenuBarStatus() {
		let runningTask = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Update menu bar",
			state: .running,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: ""
		)
		let completedTask = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Finish menu bar",
			state: .completed,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: ""
		)

		XCTAssertTrue(runningTask.isRunning)
		XCTAssertFalse(runningTask.isCompleted)
		XCTAssertTrue(completedTask.isCompleted)
		XCTAssertFalse(completedTask.isRunning)
		XCTAssertTrue(completedTask.hasUnacknowledgedCompletion)
	}

	func testClaudeCoordinatorLaunchPreservesTheBackgroundSessionContract() {
		let arguments = ClaudeHandoffCommand.coordinatorLaunchArguments(
			name: "Octo handoff token",
			modelID: "  claude-opus-4-6  ",
			reasoningEffort: .medium,
			coordinatorInstruction: "coordinate only",
			userRequest: "launch the bounded task"
		)

		XCTAssertEqual(arguments, [
			"--effort", "medium",
			"--model", "claude-opus-4-6",
			"--bg",
			"--name", "Octo handoff token",
			"--append-system-prompt", "coordinate only",
			"launch the bounded task",
		])
	}

	func testClaudeAgentLookupStaysScopedToTheAuthorizedWorkspace() {
		let workspace = URL(fileURLWithPath: "/tmp/Agent Handoffs", isDirectory: true)

		XCTAssertEqual(
			ClaudeHandoffCommand.agentListArguments(workspace: workspace),
			["agents", "--json", "--all", "--cwd", workspace.path]
		)
	}

	func testClaudeFallbackAttachesInClaudeCodeInsteadOfClaimingDesktopVisibility() {
		XCTAssertEqual(
			ClaudeHandoffCommand.attachArguments(sessionID: "session-123"),
			["attach", "session-123"]
		)
	}

	func testClaudeAgentViewCapabilityGateRequiresTheDocumentedVersion() {
		XCTAssertTrue(ClaudeHandoffSupport.supportsAgentView(versionOutput: "2.1.139 (Claude Code)"))
		XCTAssertTrue(ClaudeHandoffSupport.supportsAgentView(versionOutput: "Claude Code 2.2.0"))
		XCTAssertFalse(ClaudeHandoffSupport.supportsAgentView(versionOutput: "2.1.138 (Claude Code)"))
		XCTAssertFalse(ClaudeHandoffSupport.supportsAgentView(versionOutput: "not installed"))
		XCTAssertTrue((AgentHandoffError.claudeAgentViewUnavailable.errorDescription ?? "").contains("Claude Desktop cannot import"))
	}

	func testClaudeAuthenticationGateRequiresAnAuthenticatedCLI() {
		XCTAssertTrue(ClaudeHandoffSupport.isAuthenticated(statusOutput: #"{"loggedIn":true,"authMethod":"oauth"}"#))
		XCTAssertFalse(ClaudeHandoffSupport.isAuthenticated(statusOutput: #"{"loggedIn":false,"authMethod":"none"}"#))
		XCTAssertFalse(ClaudeHandoffSupport.isAuthenticated(statusOutput: "not JSON"))
		XCTAssertTrue((AgentHandoffError.claudeAuthenticationRequired.errorDescription ?? "").contains("claude auth login"))
	}

	func testClaudeInputArtifactsProvisionIdempotentlyAndCleanOnlyTheFailedLaunchFile() throws {
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

		let inputDirectory = try ClaudeHandoffArtifacts.provision(in: workspace)
		XCTAssertEqual(try ClaudeHandoffArtifacts.provision(in: workspace), inputDirectory)

		let failedLaunch = inputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
		let activeLaunch = inputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
		try Data([0x01]).write(to: failedLaunch)
		try Data([0x02]).write(to: activeLaunch)

		ClaudeHandoffArtifacts.removeFailedLaunchInput(at: failedLaunch, in: workspace)

		XCTAssertFalse(FileManager.default.fileExists(atPath: failedLaunch.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: activeLaunch.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: inputDirectory.path))
	}

	func testClaudeInputArtifactsRejectAConflictingFileWithAWorkspaceError() throws {
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		try Data([0x01]).write(to: ClaudeHandoffArtifacts.inputDirectoryURL(in: workspace))

		XCTAssertThrowsError(try ClaudeHandoffArtifacts.provision(in: workspace)) { error in
			XCTAssertEqual(error as? AgentHandoffError, .workspaceUnavailable)
		}
	}

	func testPlannerPromptsHonorExplicitBoundariesAndConservativeGrouping() {
		let request = AgentHandoffRequest(
			provider: .codex,
			modelID: nil,
			transcript: "Update the app",
			selectedText: nil,
			screenContext: nil,
			screenAwareInputSource: .localOCR
		)
		let guidance = HandoffPrompt.workPackagePlanningGuidance

		XCTAssertTrue(guidance.contains("`handoff start`/`handoff end`"))
		XCTAssertTrue(guidance.contains("`task start`/`task end`"))
		XCTAssertTrue(guidance.contains("Create one separate work package for each marked block"))
		XCTAssertTrue(guidance.contains("default to the fewest cohesive master work packages necessary"))
		XCTAssertTrue(guidance.contains("lists, conjunctions, and several requested actions are not themselves split signals"))
		XCTAssertTrue(guidance.contains("bare domain or path"))
		XCTAssertTrue(guidance.contains("Do not browse, fetch, evaluate, or otherwise research any URL yourself"))
		XCTAssertTrue(guidance.contains("Source URLs to research"))
		let projectCatalog = [
			CodexProjectCatalog.Project(
				id: "research",
				name: "Research Tasks",
				path: "/Users/example/GitHub/research-tasks"
			)
		]
		let plannerRequest = HandoffPrompt.codexPlannerRequest(
			request,
			projectCatalog: projectCatalog
		)
		XCTAssertTrue(plannerRequest.contains(guidance))
		XCTAssertFalse(plannerRequest.contains("handoff_discovery_workspace"))
		XCTAssertTrue(plannerRequest.contains("projectPath"))
		XCTAssertTrue(plannerRequest.contains("Research Tasks"))
		XCTAssertTrue(plannerRequest.contains("/Users/example/GitHub/research-tasks"))
		XCTAssertTrue(HandoffPrompt.claudeCoordinatorInstruction(token: "test").contains(guidance))
	}

	func testSourceContextExtractsProtocolAndBareURLsForChildResearch() {
		let context = HandoffPrompt.sourceContext(
			transcript: "Compare https://api.example.com/v1?limit=1, then check docs.example.org/guide.",
			selectedText: "Reference www.example.net/releases and docs.example.org/guide.",
			screenRecognizedText: "Also see HTTP://status.example.io/health.",
			screenPixelWidth: nil,
			screenPixelHeight: nil,
			screenCursorX: nil,
			screenCursorY: nil,
			screenAwareInputSource: nil,
			hasAttachedScreenshot: false
		)

		XCTAssertTrue(context.contains("<source_urls>"))
		XCTAssertTrue(context.contains("Source URLs to research:"))
		XCTAssertTrue(context.contains("https://api.example.com/v1?limit=1"))
		XCTAssertTrue(context.contains("https://docs.example.org/guide"))
		XCTAssertTrue(context.contains("https://www.example.net/releases"))
		XCTAssertTrue(context.contains("HTTP://status.example.io/health"))
		XCTAssertEqual(context.components(separatedBy: "https://docs.example.org/guide").count, 2)
	}

	func testCodexProjectCatalogUsesSidebarProjectsInCodexOrder() throws {
		let state = """
		{
		  "project-order": ["research", "system"],
		  "local-projects": {
		    "research": {
		      "id": "research",
		      "name": "Research Tasks",
		      "rootPaths": ["/tmp"]
		    },
		    "system": {
		      "id": "system",
		      "name": "System Files",
		      "rootPaths": ["/usr"]
		    }
		  }
		}
		"""

		let catalog = try CodexProjectCatalog(data: Data(state.utf8))

		XCTAssertEqual(
			catalog.projects,
			[
				.init(id: "research", name: "Research Tasks", path: "/tmp"),
				.init(id: "system", name: "System Files", path: "/usr"),
			]
		)
	}

	func testCodexProjectCatalogUsesCodexSidebarProjectsAndTheirNames() throws {
		let state = """
		{
		  "project-order": ["research"],
		  "local-projects": {
		    "research": {
		      "id": "research",
		      "name": "Research Tasks",
		      "rootPaths": ["/tmp"]
		    }
		  }
		}
		"""

		let catalog = try CodexProjectCatalog(data: Data(state.utf8))

		XCTAssertEqual(
			catalog.projects,
			[.init(id: "research", name: "Research Tasks", path: "/tmp")]
		)
	}

	func testCodexProjectStateDiscoveryUsesTheHomeReportedByCodex() throws {
		let temporaryRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: temporaryRoot) }
		let reportedHome = temporaryRoot.appendingPathComponent("relocated-runtime-data", isDirectory: true)
		try FileManager.default.createDirectory(at: reportedHome, withIntermediateDirectories: true)
		let stateFile = reportedHome.appendingPathComponent(".codex-global-state.json")
		try Data("{}".utf8).write(to: stateFile)
		let escapedPath = reportedHome.path.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		let initializeOutput = """
		{"id":1,"result":{"codexHome":"\(escapedPath)"}}
		{"method":"unrelated/notification","params":{}}
		"""

		XCTAssertEqual(
			CodexProjectCatalogLocation.stateFile(fromInitializeOutput: initializeOutput),
			stateFile.standardizedFileURL
		)
	}

	func testCodexProjectCatalogDoesNotTreatSavedRootsOrThreadAssignmentsAsProjects() throws {
		let state = """
		{
		  "project-order": ["research"],
		  "local-projects": {
		    "research": {
		      "id": "research",
		      "name": "Research Tasks",
		      "rootPaths": ["/tmp"]
		    }
		  },
		  "electron-saved-workspace-roots": ["/usr"],
		  "thread-project-assignments": {
		    "old-thread": { "projectId": "stale", "cwd": "/usr" }
		  }
		}
		"""

		let catalog = try CodexProjectCatalog(data: Data(state.utf8))

		XCTAssertEqual(catalog.projects, [.init(id: "research", name: "Research Tasks", path: "/tmp")])
	}

	func testAgentHandoffWorkspaceCreatesTheDedicatedFolder() throws {
		let parent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: parent) }

		let workspace = try AgentHandoffWorkspaceDirectory.ensureHandoffFolder(in: parent)

		XCTAssertEqual(workspace.lastPathComponent, "Agent Handoffs")
		XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
		XCTAssertEqual(
			AgentHandoffWorkspaceDirectory.handoffFolderURL(in: workspace),
			workspace
		)
	}
}

import Foundation
import XCTest

@testable import Octo

final class AgentHandoffClientTests: XCTestCase {
	func testCodexThreadDestinationUsesTheDesktopThreadRoute() {
		let id = "528b9ff2-d685-4c1a-b2d8-76d6a1661de3"

		let url = AgentHandoffThreadDestination.codexURL(for: id)

		XCTAssertEqual(url?.absoluteString, "codex://threads/\(id)")
	}

	func testCodexThreadDestinationRejectsMalformedThreadIDs() {
		XCTAssertNil(AgentHandoffThreadDestination.codexURL(for: "not-a-thread"))
	}

	func testHandoffTaskIsOpenableOnlyWithANativeThread() {
		let task = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Update menu bar",
			state: .pending,
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
			coordinatorInstruction: "coordinate only",
			userRequest: "launch the bounded task"
		)

		XCTAssertEqual(arguments, [
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
		let workspace = URL(fileURLWithPath: "/Users/example/GitHub", isDirectory: true)
		let guidance = HandoffPrompt.workPackagePlanningGuidance

		XCTAssertTrue(guidance.contains("`handoff start`/`handoff end`"))
		XCTAssertTrue(guidance.contains("`task start`/`task end`"))
		XCTAssertTrue(guidance.contains("Create one separate work package for each marked block"))
		XCTAssertTrue(guidance.contains("default to the fewest cohesive master work packages necessary"))
		XCTAssertTrue(guidance.contains("lists, conjunctions, and several requested actions are not themselves split signals"))
		let plannerRequest = HandoffPrompt.codexPlannerRequest(request, workspaceRoot: workspace)
		XCTAssertTrue(plannerRequest.contains(guidance))
		XCTAssertTrue(plannerRequest.contains(workspace.path))
		XCTAssertTrue(plannerRequest.contains("projectPath"))
		XCTAssertTrue(HandoffPrompt.claudeCoordinatorInstruction(token: "test").contains(guidance))
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

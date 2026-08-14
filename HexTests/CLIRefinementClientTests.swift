import Foundation
import XCTest

@testable import Octo

final class CLIRefinementClientTests: XCTestCase {
	private actor CommandRunnerStub {
		private var results: [CLIRefinementClient.ProcessResult]
		private(set) var commands: [CLIRefinementClient.Command] = []

		init(results: [CLIRefinementClient.ProcessResult]) {
			self.results = results
		}

		func run(_ command: CLIRefinementClient.Command, input: String?) throws -> CLIRefinementClient.ProcessResult {
			commands.append(command)
			return results.removeFirst()
		}
	}

	private actor ModelRefreshStub {
		private(set) var callCount = 0
		let models: [CLIRefinementClient.Model]

		init(models: [CLIRefinementClient.Model]) {
			self.models = models
		}

		func refresh() -> [CLIRefinementClient.Model] {
			callCount += 1
			return models
		}
	}

	func testCodexCommandUsesOneShotReadOnlyInvocation() throws {
		let command = try CLIRefinementClient.command(
			for: .codex,
			executableURL: URL(fileURLWithPath: "/usr/local/bin/codex")
		)

		XCTAssertEqual(command.executableURL.path, "/usr/local/bin/codex")
		XCTAssertEqual(command.arguments.first, "exec")
		XCTAssertTrue(command.arguments.contains("--sandbox"))
		XCTAssertTrue(command.arguments.contains("read-only"))
		XCTAssertTrue(command.arguments.contains("--ephemeral"))
		XCTAssertTrue(command.arguments.contains("--ignore-user-config"))
		XCTAssertTrue(command.arguments.contains("--json"))
		XCTAssertFalse(command.arguments.contains("model_reasoning_effort=\"none\""))
		XCTAssertEqual(command.arguments.last, "-")
	}

	func testClaudeCommandUsesSubscriptionCompatibleNonInteractiveInvocation() throws {
		let command = try CLIRefinementClient.command(
			for: .claude,
			executableURL: URL(fileURLWithPath: "/usr/local/bin/claude")
		)

		XCTAssertEqual(command.arguments.prefix(2), ["-p", "--input-format"])
		XCTAssertTrue(command.arguments.contains("--no-session-persistence"))
		XCTAssertTrue(command.arguments.contains("--safe-mode"))
		XCTAssertTrue(command.arguments.contains("--tools"))
		XCTAssertTrue(command.arguments.contains(""))
		XCTAssertTrue(command.arguments.contains("--system-prompt"))
		XCTAssertTrue(command.arguments.contains("text"))
		XCTAssertFalse(command.arguments.contains("--mcp-config"))
		XCTAssertFalse(command.arguments.contains("--bare"))
	}

	func testSubscriptionCommandsPassTheSelectedModel() throws {
		let codex = try CLIRefinementClient.command(
			for: .codex,
			modelID: "gpt-5.6-sol",
			executableURL: URL(fileURLWithPath: "/usr/local/bin/codex")
		)
		let claude = try CLIRefinementClient.command(
			for: .claude,
			modelID: "sonnet",
			executableURL: URL(fileURLWithPath: "/usr/local/bin/claude")
		)

		XCTAssertEqual(codex.arguments.suffix(3), ["--model", "gpt-5.6-sol", "-"])
		XCTAssertEqual(claude.arguments.suffix(2), ["--model", "sonnet"])
	}

	func testSubscriptionCommandsPassTheSelectedReasoningEffortWhenSupported() throws {
		let codex = try CLIRefinementClient.command(
			for: .codex,
			reasoningEffort: .high,
			executableURL: URL(fileURLWithPath: "/usr/local/bin/codex")
		)
		let claude = try CLIRefinementClient.command(
			for: .claude,
			reasoningEffort: .low,
			executableURL: URL(fileURLWithPath: "/usr/local/bin/claude")
		)

		XCTAssertTrue(codex.arguments.contains("model_reasoning_effort=\"high\""))
		XCTAssertTrue(claude.arguments.contains("--effort"))
		XCTAssertTrue(claude.arguments.contains("low"))
	}

	func testSubscriptionModelsReuseCachedCatalogWithoutRefreshing() async throws {
		let cached = [CLIRefinementClient.Model(id: "gpt-cached", name: "Cached")]
		let refresher = ModelRefreshStub(models: [.init(id: "gpt-live", name: "Live")])

		let models = try await CLIRefinementClient.models(
			cachedModels: cached,
			refresh: refresher.refresh
		)
		let refreshCount = await refresher.callCount

		XCTAssertEqual(models, cached)
		XCTAssertEqual(refreshCount, 0)
	}

	func testSubscriptionModelsRefreshWhenNoCatalogIsCached() async throws {
		let live = [CLIRefinementClient.Model(id: "gpt-live", name: "Live")]
		let refresher = ModelRefreshStub(models: live)

		let models = try await CLIRefinementClient.models(
			cachedModels: [],
			refresh: refresher.refresh
		)
		let refreshCount = await refresher.callCount

		XCTAssertEqual(models, live)
		XCTAssertEqual(refreshCount, 1)
	}

	func testCodexModelCatalogPersistsAcrossLaunches() throws {
		let cacheURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-models-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: cacheURL) }
		let models = [CLIRefinementClient.Model(id: "gpt-5.6-sol", name: "GPT-5.6-Sol")]

		try CLIRefinementClient.saveCodexModels(models, at: cacheURL)

		XCTAssertEqual(CLIRefinementClient.cachedCodexModels(at: cacheURL), models)
	}

	func testModelAvailabilityFailuresTriggerCatalogRecovery() {
		XCTAssertTrue(CLIRefinementClient.isModelAvailabilityFailure("Selected model is unavailable."))
		XCTAssertTrue(CLIRefinementClient.isModelAvailabilityFailure("Unknown model gpt-retired"))
		XCTAssertFalse(CLIRefinementClient.isModelAvailabilityFailure("Rate limit exceeded"))
	}

	func testClaudeResultExtractsOnlyTheTerminalResultField() {
		let output = """
		{"type":"result","result":"Refined transcript"}
		"""

		XCTAssertEqual(
			CLIRefinementClient.outputText(from: output, provider: .claude),
			"Refined transcript"
		)
		XCTAssertNil(CLIRefinementClient.outputText(from: "{\"type\":\"result\"}", provider: .claude))
		XCTAssertEqual(CLIRefinementClient.outputText(from: "Refined transcript", provider: .claude), "Refined transcript")
	}

	func testAuthenticationChecksUseOnlyTheCLIStatusCommands() {
		let codex = CLIRefinementClient.authenticationCommand(
			for: .codex,
			executableURL: URL(fileURLWithPath: "/usr/local/bin/codex")
		)
		let claude = CLIRefinementClient.authenticationCommand(
			for: .claude,
			executableURL: URL(fileURLWithPath: "/usr/local/bin/claude")
		)

		XCTAssertEqual(codex.arguments, ["login", "status"])
		XCTAssertEqual(claude.arguments, ["auth", "status"])
	}

	func testCodexLoginUsesTheManagedChatGPTSignInCommand() {
		let command = CLIRefinementClient.loginCommand(
			executableURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
		)

		XCTAssertEqual(command.provider, .codex)
		XCTAssertEqual(command.executableURL.path, "/Applications/ChatGPT.app/Contents/Resources/codex")
		XCTAssertEqual(command.arguments, ["login"])
	}

	func testCodexConnectionReusesAnExistingLoginWithoutPrompting() async throws {
		let executableURL = URL(fileURLWithPath: "/usr/local/bin/codex")
		let runner = CommandRunnerStub(results: [.init(status: 0, standardOutput: "", standardError: "")])

		try await CLIRefinementClient.connectCodexIfNeeded(
			executableURL: executableURL,
			commandRunner: runner.run
		)

		let commands = await runner.commands
		XCTAssertEqual(commands.map(\.arguments), [["login", "status"]])
	}

	func testCodexConnectionSignsInAndVerifiesAnUnauthenticatedRuntime() async throws {
		let executableURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
		let runner = CommandRunnerStub(results: [
			.init(status: 1, standardOutput: "", standardError: "Not logged in"),
			.init(status: 0, standardOutput: "Login successful", standardError: ""),
			.init(status: 0, standardOutput: "Logged in using ChatGPT", standardError: ""),
		])

		try await CLIRefinementClient.connectCodexIfNeeded(
			executableURL: executableURL,
			commandRunner: runner.run
		)

		let commands = await runner.commands
		XCTAssertEqual(commands.map(\.arguments), [
			["login", "status"],
			["login"],
			["login", "status"],
		])
	}

	func testCodexConnectionReportsAnIncompleteLogin() async {
		let executableURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
		let runner = CommandRunnerStub(results: [
			.init(status: 1, standardOutput: "", standardError: "Not logged in"),
			.init(status: 1, standardOutput: "", standardError: "Login cancelled"),
		])

		do {
			try await CLIRefinementClient.connectCodexIfNeeded(
				executableURL: executableURL,
				commandRunner: runner.run
			)
			XCTFail("Expected Codex sign-in to fail")
		} catch {
			XCTAssertEqual(error.localizedDescription, "Codex sign-in did not complete. Please try again.")
		}

		let commands = await runner.commands
		XCTAssertEqual(commands.map(\.arguments), [["login", "status"], ["login"]])
	}

	func testCodexResultUsesTerminalStandardOutput() {
		XCTAssertEqual(
			CLIRefinementClient.outputText(from: "\nRefined transcript\n", provider: .codex),
			"Refined transcript"
		)
	}

	func testCodexResultExtractsOnlyTheTerminalAgentMessageFromJSONEvents() {
		let output = """
		{"type":"thread.started","thread_id":"thread-1"}
		{"type":"item.completed","item":{"id":"item-0","type":"agent_message","text":"Refined transcript"}}
		{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}
		"""

		XCTAssertEqual(
			CLIRefinementClient.outputText(from: output, provider: .codex),
			"Refined transcript"
		)
	}

	func testFailureDiagnosticPrefersTheCLIErrorOutput() {
		XCTAssertEqual(
			CLIRefinementClient.failureDiagnostic(
				standardError: "  Rate limit exceeded. Try again in 30 seconds.  ",
				standardOutput: ""
			),
			"Rate limit exceeded. Try again in 30 seconds."
		)
	}

	func testFailureDiagnosticExtractsStructuredCLIErrorOutput() {
		XCTAssertEqual(
			CLIRefinementClient.failureDiagnostic(
				standardError: "",
				standardOutput: #"{"type":"error","error":{"message":"Selected model is unavailable."}}"#
			),
			"Selected model is unavailable."
		)
	}

	func testFailureDiagnosticSkipsCodexBannerAndPrivatePrompt() {
		let standardError = """
		OpenAI Codex v0.146.0-alpha.3.1
		--------
		user
		PRIVATE TRANSCRIPT THAT MUST NOT BE SHOWN
		"""
		let standardOutput = """
		{"type":"thread.started","thread_id":"thread-1"}
		{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"Selected model is unavailable.\"}}"}}
		"""

		let diagnostic = CLIRefinementClient.failureDiagnostic(
			standardError: standardError,
			standardOutput: standardOutput
		)

		XCTAssertEqual(diagnostic, "Selected model is unavailable.")
		XCTAssertFalse(diagnostic?.contains("PRIVATE TRANSCRIPT") == true)
	}
}

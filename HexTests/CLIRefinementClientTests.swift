import Foundation
import XCTest

@testable import Octo

final class CLIRefinementClientTests: XCTestCase {
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
		XCTAssertTrue(command.arguments.contains("model_reasoning_effort=\"none\""))
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

	func testClaudeResultExtractsOnlyTheTerminalResultField() {
		let output = """
		{"type":"result","result":"Refined transcript"}
		"""

		XCTAssertEqual(
			CLIRefinementClient.outputText(from: output, provider: .claude),
			"Refined transcript"
		)
		XCTAssertNil(CLIRefinementClient.outputText(from: "{\"type\":\"result\"}", provider: .claude))
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

	func testCodexResultUsesTerminalStandardOutput() {
		XCTAssertEqual(
			CLIRefinementClient.outputText(from: "\nRefined transcript\n", provider: .codex),
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
}

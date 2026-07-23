import Foundation
import HexCore

/// One-shot text refinement through an already authenticated local AI CLI.
/// Commands run in a temporary directory with tools disabled or read-only so the
/// transcript is the only input available to the model.
enum CLIRefinementClient {
	enum Provider: String, Sendable {
		case codex
		case claude

		var displayName: String {
			switch self {
			case .codex: "Codex"
			case .claude: "Claude"
			}
		}
	}

	struct Command: Equatable, Sendable {
		let provider: Provider
		let executableURL: URL
		let arguments: [String]
	}

	struct Model: Identifiable, Equatable, Sendable {
		let id: String
		let name: String
	}

	enum Error: LocalizedError {
		case executableNotFound(Provider)
		case notAuthenticated(Provider)
		case launchFailed(Provider)
		case executionFailed(Provider, diagnostic: String?)
		case invalidResponse(Provider, diagnostic: String?)

		var errorDescription: String? {
			switch self {
			case let .executableNotFound(provider):
				"\(provider.displayName) CLI was not found."
			case let .notAuthenticated(provider):
				"\(provider.displayName) CLI is not signed in. Sign in, then try refinement again."
			case let .launchFailed(provider):
				"\(provider.displayName) CLI could not start."
			case let .executionFailed(provider, diagnostic):
				refinementErrorDescription("\(provider.displayName) CLI could not complete refinement.", diagnostic: diagnostic)
			case let .invalidResponse(provider, diagnostic):
				refinementErrorDescription("\(provider.displayName) CLI returned no usable refinement.", diagnostic: diagnostic)
			}
		}
	}

	private static let logger = HexLog.transcription

	static func refine(provider: Provider, prompt: RefinementPrompt, modelID: String? = nil, reasoningEffort: RefinementReasoningEffort = .none) async throws -> String {
		let command = try command(for: provider, modelID: modelID, reasoningEffort: reasoningEffort)
		let input = "\(prompt.systemInstruction)\n\n\(prompt.sourceText)"
		let result = try await run(command, input: input)
		guard result.status == 0 else {
			logger.error("\(provider.displayName, privacy: .public) CLI failed status=\(result.status) stderr=\(result.standardError, privacy: .private)")
			if isAuthenticationFailure(result.standardError) {
				throw Error.notAuthenticated(provider)
			}
			throw Error.executionFailed(provider, diagnostic: failureDiagnostic(from: result))
		}
		guard let text = outputText(from: result.standardOutput, provider: provider) else {
			logger.error("\(provider.displayName, privacy: .public) CLI returned unusable output stderr=\(result.standardError, privacy: .private)")
			throw Error.invalidResponse(provider, diagnostic: failureDiagnostic(from: result))
		}
		return text
	}

	/// Checks only the local CLI's existing auth state. It never starts an interactive
	/// login and never sends a transcript or refinement prompt.
	static func authenticationError(for provider: Provider) async -> String? {
		do {
			let executableURL = try resolveExecutable(for: provider)
			let result = try await run(authenticationCommand(for: provider, executableURL: executableURL), input: nil)
			guard result.status == 0 else {
				logger.notice("\(provider.displayName, privacy: .public) CLI is not authenticated status=\(result.status) stderr=\(result.standardError, privacy: .private)")
				return Error.notAuthenticated(provider).localizedDescription
			}
			return nil
		} catch let error as Error {
			return error.localizedDescription
		} catch {
			logger.error("Could not verify \(provider.displayName, privacy: .public) CLI authentication: \(error.localizedDescription, privacy: .private)")
			return "\(provider.displayName) CLI could not verify its sign-in. Try refinement again after signing in."
		}
	}

	/// Returns the preferred already-signed-in subscription runtime, without
	/// prompting the user or sending any refinement content. Codex wins when
	/// both subscriptions are available so initial setup is deterministic.
	static func preferredAuthenticatedProvider() async -> Provider? {
		for provider in [Provider.codex, .claude] {
			guard (try? resolveExecutable(for: provider)) != nil else { continue }
			if await authenticationError(for: provider) == nil {
				return provider
			}
		}
		return nil
	}

	/// Lists the models the selected subscription can use. Codex asks its local
	/// app server, so the list reflects the signed-in account rather than a
	/// versioned list bundled with Octo. Claude Code exposes stable model aliases.
	static func models(for provider: Provider) async throws -> [Model] {
		switch provider {
		case .codex:
			return try await codexModels()
		case .claude:
			return [
				.init(id: "default", name: "Claude default"),
				.init(id: "best", name: "Claude best available"),
				.init(id: "fable", name: "Claude Fable"),
				.init(id: "sonnet", name: "Claude Sonnet"),
				.init(id: "opus", name: "Claude Opus"),
				.init(id: "haiku", name: "Claude Haiku"),
				.init(id: "opusplan", name: "Claude Opus plan / Sonnet execute"),
				.init(id: "opusplan[1m]", name: "Claude Opus plan / Sonnet execute (1M context)"),
				.init(id: "sonnet[1m]", name: "Claude Sonnet (1M context)"),
				.init(id: "opus[1m]", name: "Claude Opus (1M context)"),
			]
		}
	}

	static func command(for provider: Provider, modelID: String? = nil, reasoningEffort: RefinementReasoningEffort = .none, executableURL: URL? = nil) throws -> Command {
		let executableURL = try executableURL ?? resolveExecutable(for: provider)
		let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
		switch provider {
		case .codex:
			var arguments = [
				"exec",
				"--config", "model_reasoning_effort=\"\(reasoningEffort.rawValue)\"",
				"--sandbox", "read-only",
				"--skip-git-repo-check",
				"--ephemeral",
				"--ignore-user-config",
				"--ignore-rules",
				"--color", "never",
			]
			if let modelID, !modelID.isEmpty {
				arguments += ["--model", modelID]
			}
			arguments.append("-")
			return Command(
				provider: provider,
				executableURL: executableURL,
				arguments: arguments
			)
		case .claude:
			var arguments = [
				"-p",
				"--input-format", "text",
				"--output-format", "json",
				"--no-session-persistence",
				"--tools", "",
				"--permission-mode", "dontAsk",
				"--safe-mode",
				"--strict-mcp-config",
				"--mcp-config", "{\"mcpServers\":{}}",
			]
			if reasoningEffort != .none {
				arguments += ["--effort", reasoningEffort.rawValue]
			}
			if let modelID, !modelID.isEmpty {
				arguments += ["--model", modelID]
			}
			return Command(
				provider: provider,
				executableURL: executableURL,
				arguments: arguments
			)
		}
	}

	static func authenticationCommand(for provider: Provider, executableURL: URL) -> Command {
		switch provider {
		case .codex:
			Command(provider: provider, executableURL: executableURL, arguments: ["login", "status"])
		case .claude:
			Command(provider: provider, executableURL: executableURL, arguments: ["auth", "status"])
		}
	}

	static func outputText(from output: String, provider: Provider) -> String? {
		let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		guard provider == .claude else { return trimmed }
		guard let data = trimmed.data(using: .utf8),
			  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let result = object["result"] as? String
		else { return nil }
		let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text
	}

	private static func resolveExecutable(for provider: Provider) throws -> URL {
		let name = provider.rawValue
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		let directories = [
			"/opt/homebrew/bin",
			"/usr/local/bin",
			"/usr/bin",
			"/bin",
			"\(home)/.local/bin",
			"\(home)/Library/pnpm",
			"\(home)/.npm-global/bin",
		]
		let candidates = directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
			+ (provider == .codex ? [URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")] : [])
		guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
			throw Error.executableNotFound(provider)
		}
		return executable
	}

	private static func isAuthenticationFailure(_ standardError: String) -> Bool {
		let error = standardError.lowercased()
		return error.contains("not logged in")
			|| error.contains("not signed in")
			|| error.contains("sign in")
			|| error.contains("authentication required")
	}

	/// Preserves a bounded CLI diagnostic for History without retaining the prompt.
	static func failureDiagnostic(standardError: String, standardOutput: String) -> String? {
		let standardError = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
		let standardOutput = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
		let rawDiagnostic = standardError.isEmpty ? standardOutput : standardError
		guard !rawDiagnostic.isEmpty else { return nil }

		let diagnostic = structuredErrorMessage(from: rawDiagnostic) ?? rawDiagnostic
		let normalized = diagnostic.split(whereSeparator: \.isWhitespace).joined(separator: " ")
		guard !normalized.isEmpty else { return nil }
		return String(normalized.prefix(1_200))
	}

	private static func failureDiagnostic(from result: ProcessResult) -> String? {
		failureDiagnostic(
			standardError: result.standardError,
			standardOutput: result.standardOutput
		)
	}

	private static func refinementErrorDescription(_ summary: String, diagnostic: String?) -> String {
		guard let diagnostic, !diagnostic.isEmpty else { return summary }
		return "\(summary) \(diagnostic)"
	}

	private static func structuredErrorMessage(from output: String) -> String? {
		guard let data = output.data(using: .utf8),
			  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		return errorMessage(in: object)
	}

	private static func errorMessage(in value: Any) -> String? {
		if let text = value as? String, !text.isEmpty { return text }
		if let dictionary = value as? [String: Any] {
			for key in ["message", "error", "detail"] {
				if let value = dictionary[key], let message = errorMessage(in: value) { return message }
			}
		}
		return nil
	}

	private static func codexModels() async throws -> [Model] {
		let executableURL = try resolveExecutable(for: .codex)
		return try await requestCodexModels(executableURL: executableURL)
	}

	private static func requestCodexModels(executableURL: URL) async throws -> [Model] {
		let process = Process()
		let standardInput = Pipe()
		let standardOutput = Pipe()
		let standardError = Pipe()
		process.executableURL = executableURL
		process.arguments = ["app-server"]
		process.currentDirectoryURL = FileManager.default.temporaryDirectory
		process.standardInput = standardInput
		process.standardOutput = standardOutput
		process.standardError = standardError

		return try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { continuation in
				let lock = NSLock()
				var isFinished = false
				var pendingOutput = Data()

				func finish(_ result: Result<[Model], Swift.Error>) {
					lock.lock()
					guard !isFinished else {
						lock.unlock()
						return
					}
					isFinished = true
					lock.unlock()
					standardOutput.fileHandleForReading.readabilityHandler = nil
					continuation.resume(with: result)
					if process.isRunning {
						process.terminate()
					}
				}

				func sendModelListRequest() {
					writeJSON(["method": "initialized", "params": [:]], to: standardInput.fileHandleForWriting)
					writeJSON([
						"id": 2,
						"method": "model/list",
						"params": ["limit": 100, "includeHidden": false],
					], to: standardInput.fileHandleForWriting)
				}

				standardOutput.fileHandleForReading.readabilityHandler = { handle in
					let data = handle.availableData
					guard !data.isEmpty else { return }
					lock.lock()
					pendingOutput.append(data)
					var lines = [Data]()
					while let newline = pendingOutput.firstIndex(of: 0x0A) {
						lines.append(pendingOutput.prefix(upTo: newline))
						pendingOutput.removeSubrange(...newline)
					}
					lock.unlock()

					for line in lines {
						guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
						if message["id"] as? Int == 1 {
							sendModelListRequest()
							continue
						}
						if message["id"] as? Int == 2, let error = message["error"] as? [String: Any] {
							let message = (error["message"] as? String) ?? ""
							finish(.failure(isAuthenticationFailure(message) ? Error.notAuthenticated(.codex) : Error.executionFailed(.codex, diagnostic: message)))
							continue
						}
						guard message["id"] as? Int == 2,
							  let response = message["result"] as? [String: Any],
							  let values = response["data"] as? [[String: Any]]
						else { continue }
						let models = values.compactMap { value -> Model? in
							guard let id = (value["id"] as? String) ?? (value["model"] as? String) else { return nil }
							return Model(id: id, name: (value["displayName"] as? String) ?? id)
						}
						finish(models.isEmpty ? .failure(Error.invalidResponse(.codex, diagnostic: nil)) : .success(models))
					}
				}

				process.terminationHandler = { _ in
					let error = standardError.fileHandleForReading.readDataToEndOfFile()
					let message = String(decoding: error, as: UTF8.self)
					finish(.failure(isAuthenticationFailure(message) ? Error.notAuthenticated(.codex) : Error.executionFailed(.codex, diagnostic: message)))
				}
				do {
					try process.run()
					writeJSON([
						"id": 1,
						"method": "initialize",
						"params": [
							"clientInfo": ["name": "Octo", "version": "1.0.0"],
							"capabilities": [:],
						],
					], to: standardInput.fileHandleForWriting)
				} catch {
					finish(.failure(Error.launchFailed(.codex)))
				}
			}
		}, onCancel: {
			if process.isRunning {
				process.terminate()
			}
		})
	}

	private static func writeJSON(_ value: [String: Any], to handle: FileHandle) {
		guard let data = try? JSONSerialization.data(withJSONObject: value),
			  let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8)
		else { return }
		try? handle.write(contentsOf: line)
	}

	private static func run(_ command: Command, input: String?) async throws -> ProcessResult {
		let process = Process()
		let standardInput = Pipe()
		let standardOutput = Pipe()
		let standardError = Pipe()
		process.executableURL = command.executableURL
		process.arguments = command.arguments
		process.currentDirectoryURL = FileManager.default.temporaryDirectory
		process.standardInput = standardInput
		process.standardOutput = standardOutput
		process.standardError = standardError

		return try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { continuation in
				process.terminationHandler = { finishedProcess in
					let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
					let error = standardError.fileHandleForReading.readDataToEndOfFile()
					continuation.resume(returning: ProcessResult(
						status: finishedProcess.terminationStatus,
						standardOutput: String(decoding: output, as: UTF8.self),
						standardError: String(decoding: error, as: UTF8.self)
					))
				}
				do {
					try process.run()
					if let input {
						standardInput.fileHandleForWriting.write(Data(input.utf8))
					}
					try standardInput.fileHandleForWriting.close()
				} catch {
					continuation.resume(throwing: Error.launchFailed(command.provider))
				}
			}
		}, onCancel: {
			if process.isRunning {
				process.terminate()
			}
		})
	}

	private struct ProcessResult {
		let status: Int32
		let standardOutput: String
		let standardError: String
	}
}

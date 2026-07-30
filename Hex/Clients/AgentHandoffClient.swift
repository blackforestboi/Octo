import AppKit
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// Turns an explicit transcript handoff into durable, user-visible provider tasks.
/// Unlike `CLIRefinementClient`, child tasks retain the selected provider's ordinary
/// configuration and approval policy.
@DependencyClient
struct AgentHandoffClient {
	var launch: @Sendable (AgentHandoffRequest) -> AsyncThrowingStream<AgentHandoffEvent, Error> = { _ in
		AsyncThrowingStream { $0.finish() }
	}
	var open: @Sendable (AgentHandoffThread) async -> Void = { _ in }
	var tasks: @Sendable () throws -> [AgentHandoffTask] = { [] }
	var deleteTask: @Sendable (UUID) throws -> Void = { _ in }
	/// The user-selected local Codex project in which new handoff threads run.
	var codexProjectPath: @Sendable () -> String? = { nil }
	/// Presents the native folder picker and saves the selected project for future handoffs.
	var chooseCodexProject: @Sendable () async throws -> String = { throw AgentHandoffError.workspaceUnavailable }
}

struct AgentHandoffRequest: Equatable, Sendable {
	enum Provider: Codable, Equatable, Sendable {
		case codex
		case claude
	}

	let provider: Provider
	let modelID: String?
	let transcript: String
	/// Text captured from the focused application before recording. When present,
	/// this is the source material and `transcript` is the user's instruction for it,
	/// matching normal refinement semantics.
	let selectedText: String?
	/// Screen-aware context captured for the same recording. The selected input
	/// source determines whether the image itself may leave the device.
	let screenContext: ScreenContext?
	let screenAwareInputSource: ScreenAwareInputSource

	var hasUserRequest: Bool {
		let source = selectedText ?? transcript
		return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}
}

enum AgentHandoffThread: Equatable, Sendable {
	case codex(String)
	case claude(String)
}

/// A durable, user-readable task created from an Agent Handoff.
struct AgentHandoffTask: Equatable, Identifiable, Sendable {
	enum Status: Equatable, Sendable {
		case pending
		case threadCreated
		case registered
		case running
		case completed
		case failed
	}

	let id: UUID
	let createdAt: Date
	let provider: AgentHandoffRequest.Provider
	let title: String
	/// The last lifecycle state reported by the native handoff runner.
	let state: Status
	/// The native task to open, when this journal entry completed provider registration.
	let thread: AgentHandoffThread?
	/// The complete text delivered to the child task.
	let handoff: String

	var isOpenable: Bool {
		thread != nil
	}

	var isRunning: Bool {
		state == .running
	}

	var isCompleted: Bool {
		state == .completed
	}
}

extension Notification.Name {
	static let agentHandoffJournalDidChange = Notification.Name("io.github.blackforestboi.Octo.agentHandoffJournalDidChange")
}

enum AgentHandoffEvent: Equatable, Sendable {
	case received
	case processing
	case coordinatorStarted(AgentHandoffThread)
	case tasksFound(Int)
	case childStarted(AgentHandoffThread, ordinal: Int)
	case completed
}

enum AgentHandoffError: LocalizedError, Equatable {
	case providerUnavailable
	case noUserRequest
	case executableNotFound(String)
	case workspaceUnavailable
	case launchFailed(String)

	var errorDescription: String? {
		switch self {
		case .providerUnavailable:
			"Agent Handoff requires Codex or Claude as the refinement provider."
		case .noUserRequest:
			"Agent Handoff requires a spoken request or selected text."
		case let .executableNotFound(provider):
			"\(provider) CLI was not found."
		case .workspaceUnavailable:
			"Choose a Codex project folder before starting an agent handoff."
		case let .launchFailed(provider):
			"\(provider) could not start the agent handoff."
		}
	}
}

extension AgentHandoffClient: DependencyKey {
	static let liveValue = Self(
		launch: { request in
			AsyncThrowingStream { continuation in
				let task = Task {
					do {
						continuation.yield(.received)

						switch request.provider {
						case .codex:
							continuation.yield(.processing)
							try await CodexHandoffCoordinator.runBuffered(
								request: request,
								yield: { continuation.yield($0) }
							)
						case .claude:
							let workspace = try await AgentHandoffWorkspace.resolve()
							continuation.yield(.processing)
							try await ClaudeHandoffCoordinator.run(
								request: request,
								workspace: workspace,
								yield: { continuation.yield($0) }
							)
						}

						continuation.yield(.completed)
						continuation.finish()
					} catch is CancellationError {
						continuation.finish()
					} catch {
						continuation.finish(throwing: error)
					}
				}
				continuation.onTermination = { _ in task.cancel() }
			}
		},
		open: { thread in
			AgentHandoffThreadOpener.open(thread)
		},
		tasks: {
			try AgentHandoffJournal.shared.tasks()
		},
		deleteTask: { taskID in
			try AgentHandoffJournal.shared.deleteTask(id: taskID)
		},
		codexProjectPath: {
			AgentHandoffWorkspace.codexProjectPath()
		},
		chooseCodexProject: {
			try await AgentHandoffWorkspace.chooseCodexProject().root.path
		}
	)

	static let testValue = Self()
}

extension DependencyValues {
	var agentHandoff: AgentHandoffClient {
		get { self[AgentHandoffClient.self] }
		set { self[AgentHandoffClient.self] = newValue }
	}
}

// MARK: - Workspace authorization

private enum AgentHandoffWorkspace {
	private static let bookmarkKey = "agent-handoff-workspace-bookmark"
	private static let codexProjectBookmarkKey = "agent-handoff-codex-project-bookmark"
	/// The bookmark used by the first Codex handoff implementation. Keep using it
	/// as a migration source so an existing setup never asks for the same folder again.
	private static let legacyCodexProjectBookmarkKey = "agent-handoff-codex-projectless-bookmark"

	final class SecurityScopedDirectory: @unchecked Sendable {
		let root: URL
		private let accessURL: URL?

		init(root: URL, accessURL: URL? = nil) {
			self.root = root
			self.accessURL = accessURL
		}

		deinit {
			accessURL?.stopAccessingSecurityScopedResource()
		}
	}

	static func resolve() async throws -> URL {
		var bookmarkIsStale = false
		let bookmarkedFolder: URL?
		if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
			bookmarkedFolder = try? URL(
				resolvingBookmarkData: bookmark,
				options: [.withSecurityScope],
				relativeTo: nil,
				bookmarkDataIsStale: &bookmarkIsStale
			)
		} else {
			bookmarkedFolder = nil
		}
		if let resolved = bookmarkedFolder,
		   !bookmarkIsStale,
		   resolved.startAccessingSecurityScopedResource()
		{
			defer { resolved.stopAccessingSecurityScopedResource() }
			return try ensureHandoffFolder(in: resolved)
		}

		return try await MainActor.run {
			let panel = NSOpenPanel()
			panel.title = "Choose Agent Handoffs Folder"
			panel.message = "Octo will create and use an Agent Handoffs folder here."
			panel.prompt = "Use This Folder"
			panel.canChooseFiles = false
			panel.canChooseDirectories = true
			panel.allowsMultipleSelection = false
			panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

			guard panel.runModal() == .OK, let selected = panel.url,
				selected.startAccessingSecurityScopedResource()
			else { throw AgentHandoffError.workspaceUnavailable }
			defer { selected.stopAccessingSecurityScopedResource() }

			let folder = try ensureHandoffFolder(in: selected)
			let bookmark = try selected.bookmarkData(
				options: [.withSecurityScope],
				includingResourceValuesForKeys: nil,
				relativeTo: nil
			)
			UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
			return folder
		}
	}

	private static func ensureHandoffFolder(in selectedFolder: URL) throws -> URL {
		let handoffFolder = selectedFolder.lastPathComponent == "Agent Handoffs"
			? selectedFolder
			: selectedFolder.appendingPathComponent("Agent Handoffs", isDirectory: true)
		try FileManager.default.createDirectory(at: handoffFolder, withIntermediateDirectories: true)
		return handoffFolder
	}

	static func persistClaudeScreenshot(
		for request: AgentHandoffRequest,
		in workspace: URL,
		handoffToken: String
	) throws -> URL? {
		guard request.screenAwareInputSource.uploadsScreenshot,
			let imageData = request.screenContext?.imagePNGData
		else { return nil }
		let inputDirectory = workspace.appendingPathComponent("Handoff Inputs", isDirectory: true)
		try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
		let url = inputDirectory.appendingPathComponent("\(handoffToken).png")
		try imageData.write(to: url, options: .atomic)
		return url
	}

	/// Resolves the actual project folder for Codex handoffs. The folder is used as
	/// the thread's cwd and workspace root, so Codex discovers the same project
	/// configuration, instructions, skills, and files as a normal local task.
	static func openCodexProjectRoot() async throws -> SecurityScopedDirectory {
		for key in [codexProjectBookmarkKey, legacyCodexProjectBookmarkKey] {
			guard let selected = savedCodexProjectURL(for: key),
				selected.startAccessingSecurityScopedResource()
			else { continue }

			if key == legacyCodexProjectBookmarkKey {
				try? saveCodexProjectBookmark(for: selected)
			}
			return SecurityScopedDirectory(root: selected, accessURL: selected)
		}

		// Codex runs as Octo's child process, so a handoff must be rooted in a
		// folder the user explicitly granted to Octo. Do not silently fall back to
		// an internal workspace: that would make the task unable to reach the
		// user's project while hiding the missing permission.
		return try await chooseCodexProject()
	}

	/// Lets the user replace the project used by future Codex handoff threads.
	static func chooseCodexProject() async throws -> SecurityScopedDirectory {
		return try await MainActor.run {
			let panel = NSOpenPanel()
			panel.title = "Choose Codex Agent Handoff Project"
			panel.message = "Agent Handoff starts each Codex task in this project folder, with its normal files, instructions, tools, skills, plugins, and MCP configuration."
			panel.prompt = "Use Project"
			panel.canChooseFiles = false
			panel.canChooseDirectories = true
			panel.allowsMultipleSelection = false
			panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

			guard panel.runModal() == .OK,
				let selected = panel.url,
				selected.startAccessingSecurityScopedResource()
			else { throw AgentHandoffError.workspaceUnavailable }
			do {
				try saveCodexProjectBookmark(for: selected)
				return SecurityScopedDirectory(root: selected, accessURL: selected)
			} catch {
				selected.stopAccessingSecurityScopedResource()
				throw error
			}
		}
	}

	static func codexProjectPath() -> String? {
		for key in [codexProjectBookmarkKey, legacyCodexProjectBookmarkKey] {
			if let project = savedCodexProjectURL(for: key) {
				return project.path
			}
		}
		return nil
	}

	private static func savedCodexProjectURL(for key: String) -> URL? {
		var bookmarkIsStale = false
		guard let bookmark = UserDefaults.standard.data(forKey: key),
			let project = try? URL(
				resolvingBookmarkData: bookmark,
				options: [.withSecurityScope],
				relativeTo: nil,
				bookmarkDataIsStale: &bookmarkIsStale
			),
			!bookmarkIsStale
		else { return nil }
		return project
	}

	private static func saveCodexProjectBookmark(for project: URL) throws {
		let bookmark = try project.bookmarkData(
			options: [.withSecurityScope],
			includingResourceValuesForKeys: nil,
			relativeTo: nil
		)
		UserDefaults.standard.set(bookmark, forKey: codexProjectBookmarkKey)
	}
}

// MARK: - Codex coordinator

private enum CodexHandoffCoordinator {
	/// The planner is intentionally ephemeral and cannot create tasks. It only returns a
	/// validated manifest. The manifest is committed to Octo's journal before the runner
	/// creates or starts a single child thread.
	static func runBuffered(
		request: AgentHandoffRequest,
		yield: @escaping @Sendable (AgentHandoffEvent) -> Void
	) async throws {
		let journal = AgentHandoffJournal.shared
		let packages = try await plan(request, journal: journal)
		let handoff = try journal.append(request: request, packages: packages)
		let input = handoff.input ?? .init(request: request, screenshotPath: nil)
		yield(.tasksFound(handoff.packages.count))
		let projectAccess = try await AgentHandoffWorkspace.openCodexProjectRoot()

		try await withThrowingTaskGroup(of: Void.self) { group in
			for (offset, package) in handoff.packages.enumerated() {
				group.addTask {
					do {
						try await CodexChildRunner.run(
							handoffID: handoff.id,
							package: package,
							input: input,
							modelID: request.modelID,
							projectRoot: projectAccess.root,
							journal: journal,
						onRegistered: { threadID in
							yield(.childStarted(.codex(threadID), ordinal: offset + 1))
						}
						)
					} catch {
						journal.markFailed(handoffID: handoff.id, packageID: package.id, error: error)
						throw error
					}
				}
			}
			try await group.waitForAll()
		}
		// Opening an external app-server task before it reaches a terminal state can
		// leave Codex Desktop showing a stale snapshot. Only report readiness after
		// every turn has written its terminal state, so the native task opens complete.
		yield(.completed)
	}

	private static func plan(
		_ request: AgentHandoffRequest,
		journal: AgentHandoffJournal
	) async throws -> [AgentHandoffPackage] {
		let executable = try executable(named: "codex", fallback: "/Applications/ChatGPT.app/Contents/Resources/codex")
		let schemaURL = try journal.writePlannerSchema()
		let resultURL = journal.makeTemporaryURL(named: "planner-result", pathExtension: "json")
		let imageURL = try journal.writePlannerImage(for: request)
		defer {
			try? FileManager.default.removeItem(at: schemaURL)
			try? FileManager.default.removeItem(at: resultURL)
			if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
		}

		var arguments = [
			"exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check",
			"--output-schema", schemaURL.path,
			"--output-last-message", resultURL.path,
			HandoffPrompt.codexPlannerRequest(request),
		]
		if let imageURL {
			arguments.insert(contentsOf: ["--image", imageURL.path], at: 1)
		}
		if let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
			arguments.insert(contentsOf: ["--model", modelID], at: 1)
		}
		let result = try await runProcess(
			executable: executable,
			arguments: arguments,
			currentDirectoryURL: journal.directory
		)
		guard result.status == 0,
			let output = try? String(contentsOf: resultURL, encoding: .utf8)
		else { throw AgentHandoffError.launchFailed("Codex planner") }
		return try AgentHandoffManifest.decode(output).packages
	}
}

private struct AgentHandoffManifest: Codable, Sendable {
	let packages: [AgentHandoffPackage]

	static func decode(_ output: String) throws -> AgentHandoffManifest {
		let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
		let json = trimmed
			.replacingOccurrences(of: "```json", with: "")
			.replacingOccurrences(of: "```", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let manifest = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
		guard !manifest.packages.isEmpty,
			manifest.packages.allSatisfy({ !$0.title.isEmpty && !$0.objective.isEmpty })
		else { throw AgentHandoffError.launchFailed("Codex planner") }
		return manifest
	}
}

private struct AgentHandoffPackage: Codable, Equatable, Identifiable, Sendable {
	var id: UUID = UUID()
	let title: String
	let objective: String
	let context: String

	init(id: UUID = UUID(), title: String, objective: String, context: String = "") {
		self.id = id
		self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
		self.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
		self.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private enum CodingKeys: String, CodingKey { case title, objective, context }
}

private enum AgentHandoffPackageState: String, Codable, Sendable {
	case pending
	case threadCreated
	case registered
	case running
	case completed
	case failed
}

private extension AgentHandoffTask.Status {
	init(_ state: AgentHandoffPackageState) {
		switch state {
		case .pending: self = .pending
		case .threadCreated: self = .threadCreated
		case .registered: self = .registered
		case .running: self = .running
		case .completed: self = .completed
		case .failed: self = .failed
		}
	}
}

private struct StoredAgentHandoffPackage: Codable, Identifiable, Sendable {
	let id: UUID
	let title: String
	let objective: String
	let context: String
	var rootPath: String?
	var outputPath: String?
	/// The actual local project selected for this handoff. Optional preserves
	/// compatibility with handoffs written before project-bound threads existed.
	var projectPath: String?
	var threadID: String?
	var state: AgentHandoffPackageState
	var failure: String?

	init(_ package: AgentHandoffPackage) {
		id = package.id
		title = package.title
		objective = package.objective
		context = package.context
		state = .pending
	}

	var package: AgentHandoffPackage {
		.init(id: id, title: title, objective: objective, context: context)
	}
}

/// The complete user input that must travel with every package. Keep the screenshot
/// path separate from the JSON journal so it remains a normal local image attachment
/// for Codex rather than a large base64 blob in application state.
private struct StoredAgentHandoffInput: Codable, Sendable {
	let transcript: String
	let selectedText: String?
	let screenRecognizedText: String?
	let screenPixelWidth: Int?
	let screenPixelHeight: Int?
	let screenCursorX: Double?
	let screenCursorY: Double?
	let screenAwareInputSource: ScreenAwareInputSource?
	let screenshotPath: String?

	init(request: AgentHandoffRequest, screenshotPath: String?) {
		transcript = request.transcript
		selectedText = request.selectedText
		screenRecognizedText = request.screenContext?.recognizedText
		screenPixelWidth = request.screenContext?.pixelWidth
		screenPixelHeight = request.screenContext?.pixelHeight
		screenCursorX = request.screenContext?.cursorX
		screenCursorY = request.screenContext?.cursorY
		screenAwareInputSource = request.screenContext == nil ? nil : request.screenAwareInputSource
		self.screenshotPath = screenshotPath
	}

	/// Journals created before rich input persistence contain only the transcript.
	/// Reconstruct the child prompt from that durable source rather than omitting
	/// those previously generated tasks from the Handoffs view.
	init(legacyTranscript: String) {
		transcript = legacyTranscript
		selectedText = nil
		screenRecognizedText = nil
		screenPixelWidth = nil
		screenPixelHeight = nil
		screenCursorX = nil
		screenCursorY = nil
		screenAwareInputSource = nil
		screenshotPath = nil
	}

	var sourceContext: String {
		HandoffPrompt.sourceContext(
			transcript: transcript,
			selectedText: selectedText,
			screenRecognizedText: screenRecognizedText,
			screenPixelWidth: screenPixelWidth,
			screenPixelHeight: screenPixelHeight,
			screenCursorX: screenCursorX,
			screenCursorY: screenCursorY,
			screenAwareInputSource: screenAwareInputSource,
			hasAttachedScreenshot: screenshotPath != nil
		)
	}
}

private struct StoredAgentHandoff: Codable, Identifiable, Sendable {
	let id: UUID
	let createdAt: Date
	let provider: AgentHandoffRequest.Provider
	let transcript: String
	/// Optional so journals written before rich handoff input remain readable.
	let input: StoredAgentHandoffInput?
	var packages: [StoredAgentHandoffPackage]
}

private final class AgentHandoffJournal: @unchecked Sendable {
	static let shared = AgentHandoffJournal()

	private let lock = NSLock()
	private let fileManager = FileManager.default
	let directory: URL
	private let journalURL: URL

	private init() {
		let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
		directory = base.appendingPathComponent("io.github.blackforestboi.Octo/AgentHandoffs", isDirectory: true)
		journalURL = directory.appendingPathComponent("journal.json")
	}

	func append(request: AgentHandoffRequest, packages: [AgentHandoffPackage]) throws -> StoredAgentHandoff {
		try withLock {
			var handoffs = try load()
			let id = UUID()
			let screenshotPath = try persistHandoffScreenshot(request: request, handoffID: id)
			let handoff = StoredAgentHandoff(
				id: id,
				createdAt: Date(),
				provider: request.provider,
				transcript: request.transcript,
				input: .init(request: request, screenshotPath: screenshotPath?.path),
				packages: packages.map(StoredAgentHandoffPackage.init)
			)
			do {
				handoffs.append(handoff)
				try save(handoffs)
				return handoff
			} catch {
				if let screenshotPath { try? fileManager.removeItem(at: screenshotPath) }
				throw error
			}
		}
	}

	func tasks() throws -> [AgentHandoffTask] {
		try withLock {
			var handoffs = try load()
			if reconcileTerminalCodexTasks(&handoffs) {
				try save(handoffs)
			}
			return handoffs
				.sorted { $0.createdAt > $1.createdAt }
				.flatMap { handoff in
					let input = handoff.input ?? .init(legacyTranscript: handoff.transcript)
					return handoff.packages.map { package in
						AgentHandoffTask(
							id: package.id,
							createdAt: handoff.createdAt,
							provider: handoff.provider,
							title: package.title,
							state: .init(package.state),
							thread: thread(for: handoff.provider, id: package.threadID),
							handoff: HandoffPrompt.childRequest(package.package, input: input)
						)
					}
				}
		}
	}

	func deleteTask(id taskID: UUID) throws {
		try withLock {
			var handoffs = try load()
			guard let handoffIndex = handoffs.firstIndex(where: { handoff in
				handoff.packages.contains(where: { $0.id == taskID })
			}),
			let packageIndex = handoffs[handoffIndex].packages.firstIndex(where: { $0.id == taskID })
			else { throw AgentHandoffError.launchFailed("Agent Handoff journal") }

			handoffs[handoffIndex].packages.remove(at: packageIndex)
			if handoffs[handoffIndex].packages.isEmpty {
				handoffs.remove(at: handoffIndex)
			}
			try save(handoffs)
		}
	}

	func writePlannerImage(for request: AgentHandoffRequest) throws -> URL? {
		guard request.screenAwareInputSource.uploadsScreenshot,
			let imageData = request.screenContext?.imagePNGData
		else { return nil }
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = makeTemporaryURL(named: "planner-input", pathExtension: "png")
		try imageData.write(to: url, options: .atomic)
		return url
	}

	func prepareProject(
		handoffID: UUID,
		packageID: UUID,
		projectRoot: URL
	) throws -> URL {
		try withLock {
			var handoffs = try load()
			guard let handoffIndex = handoffs.firstIndex(where: { $0.id == handoffID }),
				let packageIndex = handoffs[handoffIndex].packages.firstIndex(where: { $0.id == packageID })
			else { throw AgentHandoffError.launchFailed("Agent Handoff journal") }
			var package = handoffs[handoffIndex].packages[packageIndex]
			package.projectPath = projectRoot.path
			handoffs[handoffIndex].packages[packageIndex] = package
			try save(handoffs)
			return projectRoot
		}
	}

	func markThreadCreated(handoffID: UUID, packageID: UUID, threadID: String) throws {
		try update(handoffID: handoffID, packageID: packageID) { package in
			package.threadID = threadID
			package.state = .threadCreated
			package.failure = nil
		}
	}

	func markRegistered(handoffID: UUID, packageID: UUID) throws {
		try update(handoffID: handoffID, packageID: packageID) { $0.state = .registered }
	}

	func markRunning(handoffID: UUID, packageID: UUID) throws {
		try update(handoffID: handoffID, packageID: packageID) { $0.state = .running }
	}

	func markCompleted(handoffID: UUID, packageID: UUID) throws {
		try update(handoffID: handoffID, packageID: packageID) { $0.state = .completed }
	}

	func markFailed(handoffID: UUID, packageID: UUID, error: Error) {
		try? update(handoffID: handoffID, packageID: packageID) {
			$0.state = .failed
			$0.failure = error.localizedDescription
		}
	}

	/// A process can exit after its task was stopped in Codex Desktop, before Octo
	/// receives a terminal notification. Repair only journal entries whose own
	/// persisted Codex session is already terminal; never infer an active task's state.
	private func reconcileTerminalCodexTasks(_ handoffs: inout [StoredAgentHandoff]) -> Bool {
		var didChange = false
		for handoffIndex in handoffs.indices where handoffs[handoffIndex].provider == .codex {
			for packageIndex in handoffs[handoffIndex].packages.indices {
				let package = handoffs[handoffIndex].packages[packageIndex]
				guard package.state == .running || package.state == .registered || package.state == .threadCreated,
					let threadID = package.threadID,
					let terminalState = terminalState(forCodexThread: threadID, createdAt: handoffs[handoffIndex].createdAt)
				else { continue }

				handoffs[handoffIndex].packages[packageIndex].state = terminalState.state
				handoffs[handoffIndex].packages[packageIndex].failure = terminalState.failure
				didChange = true
			}
		}
		return didChange
	}

	private func terminalState(forCodexThread threadID: String, createdAt: Date) -> (state: AgentHandoffPackageState, failure: String?)? {
		let sessionsRoot = fileManager.homeDirectoryForCurrentUser
			.appendingPathComponent(".codex/sessions", isDirectory: true)
		let calendar = Calendar(identifier: .gregorian)
		let candidateDays = [-1, 0, 1].compactMap {
			calendar.date(byAdding: .day, value: $0, to: createdAt)
		}

		for day in candidateDays {
			let components = calendar.dateComponents([.year, .month, .day], from: day)
			guard let year = components.year, let month = components.month, let day = components.day else { continue }
			let directory = sessionsRoot
				.appendingPathComponent(String(format: "%04d", year), isDirectory: true)
				.appendingPathComponent(String(format: "%02d", month), isDirectory: true)
				.appendingPathComponent(String(format: "%02d", day), isDirectory: true)
			guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
			guard let sessionURL = files.first(where: {
				$0.pathExtension == "jsonl" && $0.lastPathComponent.localizedCaseInsensitiveContains(threadID)
			}) else { continue }
			guard let contents = try? String(contentsOf: sessionURL, encoding: .utf8),
				let lastLine = contents.split(separator: "\n").last,
				let data = lastLine.data(using: .utf8),
				let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				let payload = event["payload"] as? [String: Any],
				let type = payload["type"] as? String
			else { continue }

			switch type {
			case "task_complete":
				return (.completed, nil)
			case "turn_aborted":
				return (.failed, "Codex task was interrupted before completing.")
			default:
				continue
			}
		}
		return nil
	}

	func writePlannerSchema() throws -> URL {
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let schema: [String: Any] = [
			"type": "object",
			"additionalProperties": false,
			"required": ["packages"],
			"properties": [
				"packages": [
					"type": "array",
					"minItems": 1,
					"items": [
						"type": "object",
						"additionalProperties": false,
						"required": ["title", "objective", "context"],
						"properties": [
							"title": ["type": "string"],
							"objective": ["type": "string"],
							"context": ["type": "string"],
						],
					],
				],
			],
		]
		let url = makeTemporaryURL(named: "planner-schema", pathExtension: "json")
		try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]).write(to: url, options: .atomic)
		return url
	}

	func makeTemporaryURL(named name: String, pathExtension: String) -> URL {
		directory.appendingPathComponent("\(name)-\(UUID().uuidString).\(pathExtension)")
	}

	private func persistHandoffScreenshot(request: AgentHandoffRequest, handoffID: UUID) throws -> URL? {
		guard request.screenAwareInputSource.uploadsScreenshot,
			let imageData = request.screenContext?.imagePNGData
		else { return nil }
		let inputDirectory = directory.appendingPathComponent("inputs", isDirectory: true)
		try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
		let url = inputDirectory.appendingPathComponent("\(handoffID.uuidString.lowercased()).png")
		try imageData.write(to: url, options: .atomic)
		return url
	}

	private func update(handoffID: UUID, packageID: UUID, _ mutate: (inout StoredAgentHandoffPackage) -> Void) throws {
		try withLock {
			var handoffs = try load()
			guard let handoffIndex = handoffs.firstIndex(where: { $0.id == handoffID }),
				let packageIndex = handoffs[handoffIndex].packages.firstIndex(where: { $0.id == packageID })
			else { throw AgentHandoffError.launchFailed("Agent Handoff journal") }
			mutate(&handoffs[handoffIndex].packages[packageIndex])
			try save(handoffs)
		}
	}

	private func load() throws -> [StoredAgentHandoff] {
		guard fileManager.fileExists(atPath: journalURL.path) else { return [] }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode([StoredAgentHandoff].self, from: Data(contentsOf: journalURL))
	}

	private func save(_ handoffs: [StoredAgentHandoff]) throws {
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		try encoder.encode(handoffs).write(to: journalURL, options: .atomic)
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: .agentHandoffJournalDidChange, object: nil)
		}
	}

	private func thread(for provider: AgentHandoffRequest.Provider, id: String?) -> AgentHandoffThread? {
		guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
		switch provider {
		case .codex: return .codex(id)
		case .claude: return .claude(id)
		}
	}

	private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		return try operation()
	}

}

/// `app-server` deliberately delegates approvals to its client. Keep those decisions
/// interactive: the handoff runner must never silently widen a user's Codex policy.
private enum CodexApprovalPresenter {
	private enum Decision {
		case accept
		case decline
		case cancel
	}

	static func response(for method: String, params: [String: Any]) -> [String: Any] {
		let decision = present(method: method, params: params)
		switch method {
		case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
			return ["decision": responseValue(for: decision)]
		case "item/permissions/requestApproval":
			guard decision == .accept else {
				// An empty profile preserves the existing sandbox rather than granting
				// any additional file-system or network access.
				return ["permissions": [:], "scope": "turn"]
			}
			return ["permissions": params["permissions"] ?? [:], "scope": "turn"]
		case "applyPatchApproval", "execCommandApproval":
			switch decision {
			case .accept: return ["decision": "approved"]
			case .decline: return ["decision": ["denied": ["rejection": "Declined in Octo"]]]
			case .cancel: return ["decision": "abort"]
			}
		default:
			return [:]
		}
	}

	static func supports(_ method: String) -> Bool {
		switch method {
		case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
			"item/permissions/requestApproval", "applyPatchApproval", "execCommandApproval":
			true
		default:
			false
		}
	}

	private static func responseValue(for decision: Decision) -> String {
		switch decision {
		case .accept: "accept"
		case .decline: "decline"
		case .cancel: "cancel"
		}
	}

	private static func present(method: String, params: [String: Any]) -> Decision {
		let showAlert = {
			let alert = NSAlert()
			alert.messageText = "Codex task needs approval"
			alert.informativeText = description(for: method, params: params)
			alert.addButton(withTitle: "Allow Once")
			alert.addButton(withTitle: "Decline")
			alert.addButton(withTitle: "Cancel Task")
			switch alert.runModal() {
			case .alertFirstButtonReturn: return Decision.accept
			case .alertSecondButtonReturn: return Decision.decline
			default: return Decision.cancel
			}
		}
		if Thread.isMainThread {
			return showAlert()
		}
		return DispatchQueue.main.sync(execute: showAlert)
	}

	private static func description(for method: String, params: [String: Any]) -> String {
		let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		let request: String
		switch method {
		case "item/fileChange/requestApproval", "applyPatchApproval":
			request = "This task wants to change files."
		case "item/permissions/requestApproval":
			request = "This task wants additional sandbox access."
		default:
			request = "This task wants to run a command."
		}
		return [request, reason].compactMap { $0 }.joined(separator: "\n\n")
	}
}

private final class JSONLineBuffer: @unchecked Sendable {
	private let lock = NSLock()
	private var data = Data()

	func append(_ chunk: Data) -> [Data] {
		lock.lock()
		defer { lock.unlock() }
		data.append(chunk)
		var lines = [Data]()
		while let newline = data.firstIndex(of: 0x0A) {
			lines.append(data.prefix(upTo: newline))
			data.removeSubrange(...newline)
		}
		return lines
	}
}

private final class CodexChildRunState: @unchecked Sendable {
	private let lock = NSLock()
	private var finished = false
	private var currentThreadID: String?
	private var didNotifyTurnStarted = false

	func takeFinish() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !finished else { return false }
		finished = true
		return true
	}

	func setThreadID(_ id: String) {
		lock.lock()
		currentThreadID = id
		lock.unlock()
	}

	var threadID: String? {
		lock.lock()
		defer { lock.unlock() }
		return currentThreadID
	}

	func takeTurnStartedNotification() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !didNotifyTurnStarted else { return false }
		didNotifyTurnStarted = true
		return true
	}

	var hasThread: Bool {
		lock.lock()
		defer { lock.unlock() }
		return currentThreadID != nil
	}

	func matches(threadID id: String?) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard let currentThreadID, let id else { return false }
		return currentThreadID == id
	}
}

private enum CodexChildRunner {
	static func run(
		handoffID: UUID,
		package: StoredAgentHandoffPackage,
		input: StoredAgentHandoffInput,
		modelID: String?,
		projectRoot: URL,
		journal: AgentHandoffJournal,
		onRegistered: @escaping @Sendable (String) -> Void
	) async throws {
		let project = try journal.prepareProject(
			handoffID: handoffID,
			packageID: package.id,
			projectRoot: projectRoot
		)
		let executable = try executable(named: "codex", fallback: "/Applications/ChatGPT.app/Contents/Resources/codex")
		let process = Process()
		let inputPipe = Pipe()
		let output = Pipe()
		let runState = CodexChildRunState()
		process.executableURL = executable
		process.arguments = ["app-server"]
		process.currentDirectoryURL = project
		process.environment = ProcessInfo.processInfo.environment
		process.standardInput = inputPipe
		process.standardOutput = output
		process.standardError = Pipe()

		try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				let lineBuffer = JSONLineBuffer()

				@Sendable func finish(_ result: Result<Void, Error>) {
					guard runState.takeFinish() else { return }
					output.fileHandleForReading.readabilityHandler = nil
					continuation.resume(with: result)
					if process.isRunning { process.terminate() }
				}

				@Sendable func send(_ value: [String: Any]) {
					guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
					try? inputPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
				}

				@Sendable func startThread() {
					var params: [String: Any] = [
						"cwd": project.path,
						"runtimeWorkspaceRoots": [project.path],
						"ephemeral": false,
						"developerInstructions": HandoffPrompt.codexChildInstruction,
					]
					if let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
						params["model"] = modelID
					}
					send(["id": 2, "method": "thread/start", "params": params])
				}

				@Sendable func startTurn(_ id: String) {
					do {
						try journal.markRunning(handoffID: handoffID, packageID: package.id)
					} catch {
						finish(.failure(error))
						return
					}
					var inputItems: [[String: Any]] = [[
						"type": "text",
						"text": HandoffPrompt.childRequest(package.package, input: input),
					]]
					if let screenshotPath = input.screenshotPath {
						inputItems.append([
							"type": "localImage",
							"path": screenshotPath,
						])
					}
					send([
						"id": 3,
						"method": "turn/start",
						"params": [
							"threadId": id,
							"input": inputItems,
						],
					])
				}

				@Sendable func processMessage(_ message: [String: Any]) {
					if let method = message["method"] as? String {
						if CodexApprovalPresenter.supports(method), let requestID = message["id"] {
							send([
								"id": requestID,
								"result": CodexApprovalPresenter.response(
									for: method,
									params: (message["params"] as? [String: Any]) ?? [:]
								),
							])
							return
						}
						guard let params = message["params"] as? [String: Any] else { return }
						if method == "turn/completed", runState.matches(threadID: params["threadId"] as? String) {
							let status = (params["turn"] as? [String: Any])?["status"] as? String
							if status == "completed" {
								do { try journal.markCompleted(handoffID: handoffID, packageID: package.id) }
								catch { finish(.failure(error)); return }
								finish(.success(()))
							} else {
								let error = AgentHandoffError.launchFailed("Codex child")
								journal.markFailed(handoffID: handoffID, packageID: package.id, error: error)
								finish(.failure(error))
							}
						}
						return
					}

					if let responseID = message["id"] as? Int {
						if let error = message["error"] as? [String: Any] {
							finish(.failure(AgentHandoffError.launchFailed((error["message"] as? String) ?? "Codex child")))
							return
						}
						switch responseID {
						case 1:
							send(["method": "initialized", "params": [:]])
							startThread()
						case 2:
							guard let result = message["result"] as? [String: Any],
								let thread = result["thread"] as? [String: Any],
								let id = thread["id"] as? String
							else { finish(.failure(AgentHandoffError.launchFailed("Codex child"))); return }
							do {
								try journal.markThreadCreated(handoffID: handoffID, packageID: package.id, threadID: id)
								try journal.markRegistered(handoffID: handoffID, packageID: package.id)
								runState.setThreadID(id)
								startTurn(id)
							} catch {
								finish(.failure(error))
							}
						case 3:
							guard let threadID = runState.threadID else {
								finish(.failure(AgentHandoffError.launchFailed("Codex child")))
								return
							}
							guard runState.takeTurnStartedNotification() else { return }
							onRegistered(threadID)
						default:
							break
						}
						return
					}
				}

				output.fileHandleForReading.readabilityHandler = { handle in
					let data = handle.availableData
					guard !data.isEmpty else { return }
					let lines = lineBuffer.append(data)
					for line in lines {
						guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
						processMessage(message)
					}
				}
				process.terminationHandler = { _ in
					let error = AgentHandoffError.launchFailed("Codex child")
					journal.markFailed(handoffID: handoffID, packageID: package.id, error: error)
					finish(.failure(error))
				}
				do {
					try process.run()
					send([
						"id": 1,
						"method": "initialize",
						"params": [
							"clientInfo": ["name": "Octo", "version": "1.0.0"],
							"capabilities": ["experimentalApi": true],
						],
					])
				} catch {
					finish(.failure(AgentHandoffError.launchFailed("Codex child")))
				}
		}
	}, onCancel: {
			// Once a canonical task exists, it belongs to the user. Cancellation only
			// detaches Octo's UI observation; it must not interrupt that task's turn.
			if process.isRunning, !runState.hasThread { process.terminate() }
	})
	}
}

// MARK: - Claude coordinator

private enum ClaudeHandoffCoordinator {
	static func run(
		request: AgentHandoffRequest,
		workspace: URL,
		yield: @escaping @Sendable (AgentHandoffEvent) -> Void
	) async throws {
		let executable = try executable(named: "claude")
		let token = UUID().uuidString.lowercased()
		let name = "Octo handoff \(token)"
		let screenshotURL = try AgentHandoffWorkspace.persistClaudeScreenshot(
			for: request,
			in: workspace,
			handoffToken: token
		)
		var arguments = [
			"--bg",
			"--name", name,
			"--append-system-prompt", HandoffPrompt.claudeCoordinatorInstruction(token: token),
			HandoffPrompt.userRequest(request, screenshotPath: screenshotURL?.path),
		]
		if let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
			arguments.insert(contentsOf: ["--model", modelID], at: 0)
		}

		let result = try await runProcess(
			executable: executable,
			arguments: arguments,
			currentDirectoryURL: workspace
		)
		guard result.status == 0 else { throw AgentHandoffError.launchFailed("Claude") }

		let coordinatorID: String
		if let returnedID = uuid(in: result.output) {
			coordinatorID = returnedID
		} else {
			coordinatorID = try await findClaudeAgent(named: name, executable: executable, workspace: workspace)
		}
		yield(.coordinatorStarted(.claude(coordinatorID)))

		let children = try? await findClaudeAgents(
			withNamePrefix: "Octo handoff child \(token)",
			executable: executable,
			workspace: workspace
		)
		for (offset, childID) in (children ?? []).enumerated() {
			yield(.tasksFound(offset + 1))
			yield(.childStarted(.claude(childID), ordinal: offset + 1))
		}
	}

	private static func findClaudeAgent(named: String, executable: URL, workspace: URL) async throws -> String {
		let agents = try await findClaudeAgents(withNamePrefix: named, executable: executable, workspace: workspace)
		guard let id = agents.first else { throw AgentHandoffError.launchFailed("Claude") }
		return id
	}

	private static func findClaudeAgents(withNamePrefix name: String, executable: URL, workspace: URL) async throws -> [String] {
		let result = try await runProcess(
			executable: executable,
			arguments: ["agents", "--json", "--all", "--cwd", workspace.path],
			currentDirectoryURL: workspace
		)
		guard result.status == 0 else { return [] }
		let root = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
		return AgentJSON.findIDs(in: root, matchingNamePrefix: name)
	}
}

private enum AgentJSON {
	static func findIDs(in value: Any, matchingNamePrefix name: String) -> [String] {
		var result = [String]()
		func visit(_ value: Any) {
			if let dictionary = value as? [String: Any] {
				let displayName = (dictionary["name"] as? String) ?? (dictionary["display_name"] as? String) ?? ""
				if displayName.hasPrefix(name),
				   let id = (dictionary["id"] as? String) ?? (dictionary["session_id"] as? String) ?? (dictionary["sessionId"] as? String),
				   !result.contains(id)
				{
					result.append(id)
				}
				dictionary.values.forEach(visit)
			} else if let values = value as? [Any] {
				values.forEach(visit)
			}
		}
		visit(value)
		return result
	}
}

// MARK: - Provider utilities

private enum HandoffPrompt {
	static let codexChildInstruction = """
	You own one bounded Agent Handoff work package. First discover only the relevant configured native tools, skills, plugins, and MCP servers in the user's normal environment. Then execute this package under the user's ordinary approval rules. Do not add a Nomen dependency or a custom discovery bridge. Do not delegate, split, or broaden the package.
	"""

	static func codexPlannerRequest(_ request: AgentHandoffRequest) -> String {
		"""
		You are an ephemeral Agent Handoff planner. Split the user's request into independently executable, bounded work packages. Do not inspect tools, skills, plugins, MCP servers, files, or the workspace. Do not execute any work and do not create tasks. Return only JSON matching the supplied schema. Each package needs a short title, an objective that can be completed by one agent, and only the user context required for that objective. There is no arbitrary package limit. The full handoff input below, including any attached screenshot, is the same user context that each child task will receive.

		\(sourceContext(
			transcript: request.transcript,
			selectedText: request.selectedText,
			screenContext: request.screenContext,
			screenAwareInputSource: request.screenAwareInputSource
		))
		"""
	}

	static func childRequest(_ package: AgentHandoffPackage, input: StoredAgentHandoffInput) -> String {
		let context = package.context.isEmpty ? "" : "\n\nNecessary user context:\n\(package.context)"
		return """
		Complete this bounded objective:
		\(package.objective)\(context)

		Full original handoff input:
		\(input.sourceContext)
		"""
	}

	static func claudeCoordinatorInstruction(token: String) -> String {
		"""
		You are the Octo agent-handoff coordinator. Your only job is to split the user's request into independent, bounded work packages and start one new visible Claude background session for every package. Do not inspect configured tools, skills, plugins, MCP servers, the workspace, or project files. Do not perform any package's task work yourself. There is no task-count cap.

		Use Claude's native `claude --bg` sessions in the current working directory. Name each child `Octo handoff child \(token) <short title>`. Do not disable the child's normal configuration, skills, plugins, MCP servers, or approval rules. Pass this focused system instruction to every child with `--append-system-prompt`: first discover the relevant configured native tools, skills, plugins, and MCP servers in the user's normal environment; then execute only its bounded objective under the user's ordinary approval rules. Do not add a Nomen dependency or custom discovery bridge. Give each child the complete original handoff input as well as its bounded objective. If the input includes a `screen_screenshot_path`, include that path verbatim so the child can inspect the user-provided screenshot when relevant. Do not create a local task manifest and do not ask Octo to create the child sessions.
		"""
	}

	static func userRequest(_ request: AgentHandoffRequest, screenshotPath: String? = nil) -> String {
		let context = sourceContext(
			transcript: request.transcript,
			selectedText: request.selectedText,
			screenRecognizedText: request.screenContext?.recognizedText,
			screenPixelWidth: request.screenContext?.pixelWidth,
			screenPixelHeight: request.screenContext?.pixelHeight,
			screenCursorX: request.screenContext?.cursorX,
			screenCursorY: request.screenContext?.cursorY,
			screenAwareInputSource: request.screenContext == nil ? nil : request.screenAwareInputSource,
			hasAttachedScreenshot: screenshotPath == nil && request.screenContext != nil && request.screenAwareInputSource.uploadsScreenshot
		)
		let screenshotReference = screenshotPath.map { "\n\n<screen_screenshot_path>\n\($0)\n</screen_screenshot_path>" } ?? ""
		return "The user's handoff request is below. Create the native child tasks now.\n\n\(context)\(screenshotReference)"
	}

	static func sourceContext(
		transcript: String,
		selectedText: String?,
		screenContext: ScreenContext?,
		screenAwareInputSource: ScreenAwareInputSource
	) -> String {
		sourceContext(
			transcript: transcript,
			selectedText: selectedText,
			screenRecognizedText: screenContext?.recognizedText,
			screenPixelWidth: screenContext?.pixelWidth,
			screenPixelHeight: screenContext?.pixelHeight,
			screenCursorX: screenContext?.cursorX,
			screenCursorY: screenContext?.cursorY,
			screenAwareInputSource: screenContext == nil ? nil : screenAwareInputSource,
			hasAttachedScreenshot: screenContext != nil && screenAwareInputSource.uploadsScreenshot
		)
	}

	static func sourceContext(
		transcript: String,
		selectedText: String?,
		screenRecognizedText: String?,
		screenPixelWidth: Int?,
		screenPixelHeight: Int?,
		screenCursorX: Double?,
		screenCursorY: Double?,
		screenAwareInputSource: ScreenAwareInputSource?,
		hasAttachedScreenshot: Bool
	) -> String {
		var sections = [String]()
		let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		if let selectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selectedText.isEmpty {
			sections.append("<selected_text>\n\(selectedText)\n</selected_text>")
			if !trimmedTranscript.isEmpty {
				sections.append("<spoken_instruction>\n\(trimmedTranscript)\n</spoken_instruction>")
			}
		} else {
			sections.append("<transcript>\n\(trimmedTranscript)\n</transcript>")
		}

		if let screenAwareInputSource {
			let recognizedText = (screenRecognizedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			let dimensions = [screenPixelWidth, screenPixelHeight]
				.compactMap { $0.map(String.init) }
				.joined(separator: " × ")
			let cursor = if let screenCursorX, let screenCursorY {
				"x=\(Int(screenCursorX)), y=\(Int(screenCursorY))"
			} else {
				"Unavailable"
			}
			let screenshotStatus = hasAttachedScreenshot
				? "A screenshot is attached to this input."
				: "No screenshot is attached; use only the local OCR and metadata below."
			sections.append("""
			<screen_context>
			\(screenshotStatus)
			Screen input source: \(screenAwareInputSource.rawValue)
			Pixel dimensions: \(dimensions.isEmpty ? "Unavailable" : dimensions)
			Cursor position: \(cursor)
			<local_ocr>
			\(recognizedText.isEmpty ? "No text was recognized locally." : recognizedText)
			</local_ocr>
			</screen_context>
			""")
		}

		return sections.joined(separator: "\n\n")
	}
}

private struct ProcessResult {
	let status: Int32
	let output: String
}

private func executable(named name: String, fallback: String? = nil) throws -> URL {
	let home = FileManager.default.homeDirectoryForCurrentUser.path
	let directories = [
		"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
		"\(home)/.local/bin", "\(home)/Library/pnpm", "\(home)/.npm-global/bin",
	]
	let candidates = directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
		+ (fallback.map { [URL(fileURLWithPath: $0)] } ?? [])
	guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
		throw AgentHandoffError.executableNotFound(name.capitalized)
	}
	return executable
}

private func runProcess(executable: URL, arguments: [String], currentDirectoryURL: URL) async throws -> ProcessResult {
	let process = Process()
	let output = Pipe()
	let error = Pipe()
	process.executableURL = executable
	process.arguments = arguments
	process.currentDirectoryURL = currentDirectoryURL
	process.environment = ProcessInfo.processInfo.environment
	process.standardOutput = output
	process.standardError = error

	return try await withTaskCancellationHandler(operation: {
		try await withCheckedThrowingContinuation { continuation in
			process.terminationHandler = { completed in
				let standardOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
				continuation.resume(returning: .init(status: completed.terminationStatus, output: standardOutput))
			}
			do {
				try process.run()
			} catch {
				continuation.resume(throwing: AgentHandoffError.launchFailed(executable.lastPathComponent.capitalized))
			}
		}
	}, onCancel: {
		if process.isRunning { process.terminate() }
	})
}

private func uuid(in value: String) -> String? {
	let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
	guard let expression = try? NSRegularExpression(pattern: pattern),
		  let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
		  let range = Range(match.range, in: value)
	else { return nil }
	return String(value[range])
}

enum AgentHandoffThreadDestination {
	static func codexURL(for threadID: String) -> URL? {
		guard UUID(uuidString: threadID) != nil else { return nil }
		var components = URLComponents()
		components.scheme = "codex"
		components.host = "threads"
		components.path = "/\(threadID)"
		return components.url
	}
}

private enum AgentHandoffThreadOpener {
	static func open(_ thread: AgentHandoffThread) {
		switch thread {
		case let .codex(id):
			guard let url = AgentHandoffThreadDestination.codexURL(for: id) else { return }
			NSWorkspace.shared.open(url)
		case let .claude(id):
			guard let agentExecutable = try? executable(named: "claude") else { return }
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
			process.arguments = ["-a", "Terminal", "--args", agentExecutable.path, "--resume", id]
			try? process.run()
		}
	}
}

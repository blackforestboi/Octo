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
	var acknowledgeTaskCompletions: @Sendable ([UUID]) throws -> Void = { _ in }
	var deleteTask: @Sendable (UUID) throws -> Void = { _ in }
}

struct AgentHandoffRequest: Equatable, Sendable {
	enum Provider: Codable, Equatable, Sendable {
		case codex
		case claude
	}

	let provider: Provider
	let modelID: String?
	let reasoningEffort: RefinementReasoningEffort
	let transcript: String
	/// Text captured from the focused application before recording. When present,
	/// this is the source material and `transcript` is the user's instruction for it,
	/// matching normal refinement semantics.
	let selectedText: String?
	/// Screen-aware context captured for the same recording. The selected input
	/// source determines whether the image itself may leave the device.
	let screenContext: ScreenContext?
	let screenAwareInputSource: ScreenAwareInputSource

	init(
		provider: Provider,
		modelID: String?,
		reasoningEffort: RefinementReasoningEffort = .medium,
		transcript: String,
		selectedText: String?,
		screenContext: ScreenContext?,
		screenAwareInputSource: ScreenAwareInputSource
	) {
		self.provider = provider
		self.modelID = modelID
		self.reasoningEffort = reasoningEffort
		self.transcript = transcript
		self.selectedText = selectedText
		self.screenContext = screenContext
		self.screenAwareInputSource = screenAwareInputSource
	}

	var hasUserRequest: Bool {
		let source = selectedText ?? transcript
		return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}
}

enum AgentHandoffThread: Equatable, Hashable, Sendable {
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
	/// The native task to open after this journal entry's child task is done.
	let thread: AgentHandoffThread?
	/// The complete text delivered to the child task.
	let handoff: String
	/// The project root the coordinator discovered for this handoff package.
	let projectPath: String?
	/// Whether the user has opened this completed task since Octo recorded its completion.
	let isCompletionAcknowledged: Bool

	init(
		id: UUID,
		createdAt: Date,
		provider: AgentHandoffRequest.Provider,
		title: String,
		state: Status,
		thread: AgentHandoffThread?,
		handoff: String,
		projectPath: String? = nil,
		isCompletionAcknowledged: Bool = false
	) {
		self.id = id
		self.createdAt = createdAt
		self.provider = provider
		self.title = title
		self.state = state
		self.thread = thread
		self.handoff = handoff
		self.projectPath = projectPath
		self.isCompletionAcknowledged = isCompletionAcknowledged
	}

	var isOpenable: Bool {
		state == .completed && thread != nil
	}

	var isRunning: Bool {
		state == .running
	}

	var isCompleted: Bool {
		state == .completed
	}

	var hasUnacknowledgedCompletion: Bool {
		isCompleted && !isCompletionAcknowledged
	}
}

extension Notification.Name {
	static let agentHandoffJournalDidChange = Notification.Name("io.github.blackforestboi.Octo.agentHandoffJournalDidChange")
}

enum AgentHandoffEvent: Equatable, Sendable {
	case received
	case processing
	case coordinatorSubmitted
	case coordinatorStarted(AgentHandoffThread)
	case tasksFound(Int)
	case childStarted(AgentHandoffThread, ordinal: Int)
	case completed
}

enum AgentHandoffError: LocalizedError, Equatable {
	case providerUnavailable
	case claudeAgentViewUnavailable
	case claudeAuthenticationRequired
	case noUserRequest
	case executableNotFound(String)
	case workspaceUnavailable
	case projectCatalogUnavailable
	case projectCatalogEmpty
	case launchFailed(String, diagnostic: String? = nil)

	var errorDescription: String? {
		switch self {
		case .providerUnavailable:
			"Agent Handoff requires Codex or Claude as the refinement provider."
		case .claudeAgentViewUnavailable:
			"Claude handoffs require Claude Code Agent View (version 2.1.139 or later). Update Claude Code or enable Agent View, then use `claude agents` to view or attach to handoffs. Claude Desktop cannot import these local sessions."
		case .claudeAuthenticationRequired:
			"Claude CLI is not signed in. Run `claude auth login`, then start the handoff again."
		case .noUserRequest:
			"Agent Handoff requires a spoken request or selected text."
		case let .executableNotFound(provider):
			"\(provider) CLI was not found."
		case .workspaceUnavailable:
			"Choose an Agent Handoff workspace or Agent Handoffs folder before starting an agent handoff."
		case .projectCatalogUnavailable:
			"Codex’s project-state file is unavailable. Open Codex Desktop once, then try again."
		case .projectCatalogEmpty:
			"Codex has no available local projects. Add or open a project in Codex Desktop, then try again."
		case let .launchFailed(provider, diagnostic):
			["\(provider) could not start the agent handoff.", diagnostic]
				.compactMap { $0 }
				.joined(separator: " ")
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
							let workspace = try await AgentHandoffWorkspace.openClaudeHandoffRoot()
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
		acknowledgeTaskCompletions: { taskIDs in
			try AgentHandoffJournal.shared.acknowledgeCompletions(of: taskIDs)
		},
		deleteTask: { taskID in
			try AgentHandoffJournal.shared.deleteTask(id: taskID)
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

	/// Verifies that Codex Desktop has created its project-state file. Octo is not
	/// sandboxed, so it can use the home reported by the active Codex runtime.
	@MainActor
	static func authorizeCodexProjectCatalog() async throws {
		_ = try await CodexProjectCatalogLocation.discoverStateFile()
	}

	static func openCodexProjectCatalog() async throws -> URL {
		try await CodexProjectCatalogLocation.discoverStateFile()
	}

	/// Resolves the dedicated Claude workspace and retains its sandbox access until
	/// the caller finishes launching native sessions from it.
	static func openClaudeHandoffRoot() async throws -> SecurityScopedDirectory {
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
			do {
				let folder = try ensureHandoffFolder(in: resolved)
				// Older builds stored the parent directory. Migrate them to an exact
				// workspace bookmark while the user-granted parent scope is active.
				try saveClaudeHandoffBookmark(for: folder)
				return .init(root: folder, accessURL: resolved)
			} catch {
				resolved.stopAccessingSecurityScopedResource()
				throw error
			}
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
			do {
				let folder = try ensureHandoffFolder(in: selected)
				try saveClaudeHandoffBookmark(for: folder)
				return .init(root: folder, accessURL: selected)
			} catch {
				selected.stopAccessingSecurityScopedResource()
				throw error
			}
		}
	}

	private static func ensureHandoffFolder(in selectedFolder: URL) throws -> URL {
		try AgentHandoffWorkspaceDirectory.ensureHandoffFolder(in: selectedFolder)
	}

	private static func saveClaudeHandoffBookmark(for folder: URL) throws {
		let bookmark = try folder.bookmarkData(
			options: [.withSecurityScope],
			includingResourceValuesForKeys: nil,
			relativeTo: nil
		)
		UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
	}

	static func persistClaudeScreenshot(
		for request: AgentHandoffRequest,
		in workspace: URL,
		handoffToken: String
	) throws -> URL? {
		guard request.screenAwareInputSource.uploadsScreenshot,
			let imageData = request.screenContext?.imagePNGData
		else { return nil }
		let inputDirectory = try ClaudeHandoffArtifacts.provision(in: workspace)
		let url = inputDirectory.appendingPathComponent("\(handoffToken).png")
		try imageData.write(to: url, options: .atomic)
		return url
	}

}

enum CodexProjectCatalogLocation {
	private static let cachedHomeKey = "agent-handoff-discovered-codex-home"
	private static let stateFileName = ".codex-global-state.json"

	static func discoverStateFile(fileManager: FileManager = .default) async throws -> URL {
		let codex = try executable(named: "codex", fallback: "/Applications/ChatGPT.app/Contents/Resources/codex")
		let output = try await initializeAppServer(executableURL: codex)
		guard let stateFile = stateFile(fromInitializeOutput: output, fileManager: fileManager) else {
			throw AgentHandoffError.projectCatalogUnavailable
		}
		UserDefaults.standard.set(stateFile.deletingLastPathComponent().path, forKey: cachedHomeKey)
		return stateFile
	}

	static func stateFile(
		fromInitializeOutput output: String,
		fileManager: FileManager = .default
	) -> URL? {
		guard let home = codexHome(fromInitializeOutput: output) else { return nil }
		let stateFile = home.appendingPathComponent(stateFileName, isDirectory: false).standardizedFileURL
		return fileManager.isReadableFile(atPath: stateFile.path) ? stateFile : nil
	}

	static func cachedHomeDirectory(fileManager: FileManager = .default) -> URL? {
		guard let path = UserDefaults.standard.string(forKey: cachedHomeKey) else { return nil }
		let home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			return nil
		}
		return home
	}

	private static func codexHome(fromInitializeOutput output: String) -> URL? {
		for line in output.split(whereSeparator: \.isNewline) {
			guard let data = line.data(using: .utf8),
				let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				(message["id"] as? NSNumber)?.intValue == 1,
				let result = message["result"] as? [String: Any],
				let path = (result["codexHome"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
				!path.isEmpty
			else { continue }
			return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
		}
		return nil
	}

	private static func initializeAppServer(executableURL: URL) async throws -> String {
		let process = Process()
		let standardInput = Pipe()
		let standardOutput = Pipe()
		let standardError = Pipe()
		process.executableURL = executableURL
		process.arguments = ["app-server"]
		process.currentDirectoryURL = FileManager.default.temporaryDirectory
		process.environment = ProcessInfo.processInfo.environment
		process.standardInput = standardInput
		process.standardOutput = standardOutput
		process.standardError = standardError
		let request: [String: Any] = [
			"id": 1,
			"method": "initialize",
			"params": [
				"clientInfo": ["name": "Octo", "version": "1.0.0"],
				"capabilities": [:],
			],
		]
		guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
			throw AgentHandoffError.projectCatalogUnavailable
		}

		return try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { continuation in
				let lock = NSLock()
				var isFinished = false

				func finish(_ result: Result<String, Error>) {
					lock.lock()
					guard !isFinished else {
						lock.unlock()
						return
					}
					isFinished = true
					lock.unlock()
					continuation.resume(with: result)
				}

				process.terminationHandler = { completed in
					let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
					guard completed.terminationStatus == 0 else {
						let diagnostic = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
						finish(.failure(AgentHandoffError.launchFailed(
							"Codex app server",
							diagnostic: conciseProcessDiagnostic(diagnostic)
						)))
						return
					}
					finish(.success(output))
				}
				do {
					try process.run()
					try standardInput.fileHandleForWriting.write(contentsOf: requestData + Data([0x0A]))
					try standardInput.fileHandleForWriting.close()
				} catch {
					finish(.failure(error))
					if process.isRunning { process.terminate() }
				}
			}
		}, onCancel: {
			if process.isRunning { process.terminate() }
		})
	}
}

/// Settings uses this small surface to verify that Codex Desktop's read-only project
/// catalogue is available from the home reported by the resolved Codex runtime.
enum CodexProjectCatalogAccess {
	@MainActor
	static func authorize() async throws {
		try await AgentHandoffWorkspace.authorizeCodexProjectCatalog()
	}
}

struct CodexProjectCatalog: Equatable, Sendable {
	struct Project: Codable, Equatable, Sendable {
		let id: String
		let name: String
		let path: String
	}

	let projects: [Project]

	init(projects: [Project]) {
		self.projects = projects
	}

	init(data: Data, fileManager: FileManager = .default) throws {
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw AgentHandoffError.projectCatalogUnavailable
		}
		let projectOrder = root["project-order"] as? [String] ?? []
		let localProjects = root["local-projects"] as? [String: [String: Any]] ?? [:]
		var sidebarProjects = [String: (name: String, rootPaths: [String])]()
		for (key, project) in localProjects {
			let projectID = (project["id"] as? String) ?? key
			guard let name = (project["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
			let rootPaths = (project["rootPaths"] as? [String] ?? [])
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			sidebarProjects[projectID] = (name: name, rootPaths: rootPaths)
		}
		var seenPaths = Set<String>()
		let orderedProjectIDs = projectOrder.filter { sidebarProjects[$0] != nil } + sidebarProjects.keys
			.filter { !projectOrder.contains($0) }
			.sorted()
		let orderedCandidates: [(id: String, name: String, path: String)] = orderedProjectIDs.flatMap { id in
			guard let project = sidebarProjects[id] else {
				return [(id: String, name: String, path: String)]()
			}
			return project.rootPaths.map { (id: id, name: project.name, path: $0) }
		}

		projects = orderedCandidates.compactMap { candidate in
			let standardizedPath = URL(fileURLWithPath: candidate.path, isDirectory: true).standardizedFileURL.path
			var isDirectory: ObjCBool = false
			guard fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
				isDirectory.boolValue,
				seenPaths.insert(standardizedPath).inserted
			else { return nil }
			return .init(
				id: candidate.id,
				name: candidate.name,
				path: standardizedPath
			)
		}
	}

	static func load(from file: URL) throws -> Self {
		try .init(data: Data(contentsOf: file))
	}
}

/// Pure and file-system setup helpers kept separate from the security-scoped
/// bookmark flow so the first-use workspace contract can be regression tested.
enum AgentHandoffWorkspaceDirectory {
	static func handoffFolderURL(in selectedFolder: URL) -> URL {
		selectedFolder.lastPathComponent == "Agent Handoffs"
			? selectedFolder
			: selectedFolder.appendingPathComponent("Agent Handoffs", isDirectory: true)
	}

	static func ensureHandoffFolder(in selectedFolder: URL) throws -> URL {
		let handoffFolder = handoffFolderURL(in: selectedFolder)
		var isDirectory: ObjCBool = false
		if FileManager.default.fileExists(atPath: handoffFolder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
			throw AgentHandoffError.workspaceUnavailable
		}
		try FileManager.default.createDirectory(at: handoffFolder, withIntermediateDirectories: true)
		return handoffFolder
	}
}

/// Octo owns only the handoff input files it writes into the user-authorized
/// workspace. Claude Code owns its supervisor, sessions, and `~/.claude`
/// configuration, so this integration must never bootstrap or clean those paths.
enum ClaudeHandoffArtifacts {
	private static let inputDirectoryName = "Handoff Inputs"

	static func inputDirectoryURL(in workspace: URL) -> URL {
		workspace.appendingPathComponent(inputDirectoryName, isDirectory: true)
	}

	/// Creating an existing input directory is deliberately harmless, so every
	/// launch can provision it without a separate first-run state machine.
	static func provision(in workspace: URL) throws -> URL {
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw AgentHandoffError.workspaceUnavailable
		}
		let inputDirectory = inputDirectoryURL(in: workspace)
		if FileManager.default.fileExists(atPath: inputDirectory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
			throw AgentHandoffError.workspaceUnavailable
		}
		try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
		return inputDirectory
	}

	/// Failed launches may leave an image that no native Claude session can read.
	/// Delete only the UUID-named file created for that launch; never remove the
	/// shared directory or a sibling session's still-needed input.
	static func removeFailedLaunchInput(at url: URL, in workspace: URL) {
		let inputDirectory = inputDirectoryURL(in: workspace).standardizedFileURL
		let candidate = url.standardizedFileURL
		guard candidate.deletingLastPathComponent().path == inputDirectory.path,
			candidate.pathExtension.lowercased() == "png",
			UUID(uuidString: candidate.deletingPathExtension().lastPathComponent) != nil
		else { return }
		try? FileManager.default.removeItem(at: candidate)
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
		let projectState = try await AgentHandoffWorkspace.openCodexProjectCatalog()
		let projectCatalog = try CodexProjectCatalog.load(from: projectState)
		let eligibleProjects = projectCatalog.projects
		guard !eligibleProjects.isEmpty else { throw AgentHandoffError.projectCatalogEmpty }
		let allowedProjectPaths = Set(eligibleProjects.map(\.path))
		let packages = try await plan(
			request,
			projectCatalog: eligibleProjects,
			journal: journal,
			onSubmitted: { yield(.coordinatorSubmitted) }
		)
		let handoff = try journal.append(request: request, packages: packages)
		let input = handoff.input ?? .init(request: request, screenshotPath: nil)
		yield(.tasksFound(handoff.packages.count))

		try await withThrowingTaskGroup(of: Void.self) { group in
			for (offset, package) in handoff.packages.enumerated() {
				group.addTask {
					do {
						guard let projectRoot = validatedProjectRoot(
							at: package.projectPath,
							allowedProjectPaths: allowedProjectPaths
						) else { throw AgentHandoffError.launchFailed("Codex project routing") }
						try await CodexChildRunner.run(
							handoffID: handoff.id,
							package: package,
							input: input,
							modelID: request.modelID,
							reasoningEffort: request.reasoningEffort,
							projectRoot: projectRoot,
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
		projectCatalog: [CodexProjectCatalog.Project],
		journal: AgentHandoffJournal,
		onSubmitted: @escaping @Sendable () -> Void
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
			HandoffPrompt.codexPlannerRequest(
				request,
				projectCatalog: projectCatalog
			),
		]
		if let imageURL {
			arguments.insert(contentsOf: ["--image", imageURL.path], at: 1)
		}
		if let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
			arguments.insert(contentsOf: ["--model", modelID], at: 1)
		}
		if request.reasoningEffort != .none {
			arguments.insert(
				contentsOf: ["--config", "model_reasoning_effort=\"\(request.reasoningEffort.rawValue)\""],
				at: arguments.count - 1
			)
		}
		onSubmitted()
		let result = try await runProcess(
			executable: executable,
			arguments: arguments,
			currentDirectoryURL: FileManager.default.temporaryDirectory
		)
		guard result.status == 0 else {
			throw AgentHandoffError.launchFailed(
				"Codex planner",
				diagnostic: plannerFailureDescription(for: result)
			)
		}
		guard let output = try? String(contentsOf: resultURL, encoding: .utf8) else {
			throw AgentHandoffError.launchFailed(
				"Codex planner",
				diagnostic: "Codex completed without returning a task plan."
			)
		}
		return try AgentHandoffManifest.decode(
			output,
			allowedProjectPaths: Set(projectCatalog.map(\.path))
		).packages
	}

	private static func plannerFailureDescription(for result: ProcessResult) -> String {
		let diagnostic = conciseProcessDiagnostic(result.error)
		let prefix = "Codex exited with status \(result.status)."
		return [prefix, diagnostic].compactMap { $0 }.joined(separator: " ")
	}

	fileprivate static func validatedProjectRoot(
		at path: String?,
		allowedProjectPaths: Set<String>
	) -> URL? {
		guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
			return nil
		}
		let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
		guard allowedProjectPaths.contains(candidate.path) else { return nil }
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			return nil
		}
		return candidate
	}
}

private struct AgentHandoffManifest: Codable, Sendable {
	let packages: [AgentHandoffPackage]

	static func decode(
		_ output: String,
		allowedProjectPaths: Set<String>
	) throws -> AgentHandoffManifest {
		let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
		let json = trimmed
			.replacingOccurrences(of: "```json", with: "")
			.replacingOccurrences(of: "```", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let manifest: Self
		do {
			manifest = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
		} catch {
			throw AgentHandoffError.launchFailed(
				"Codex planner",
				diagnostic: "Codex returned a task plan Octo could not read: \(error.localizedDescription)"
			)
		}
		guard !manifest.packages.isEmpty,
			manifest.packages.allSatisfy({
				!$0.title.isEmpty && !$0.objective.isEmpty
					&& CodexHandoffCoordinator.validatedProjectRoot(
						at: $0.projectPath,
						allowedProjectPaths: allowedProjectPaths
					) != nil
			})
		else {
			throw AgentHandoffError.launchFailed(
				"Codex planner",
				diagnostic: "Codex returned no usable tasks for a project in its current project catalogue."
			)
		}
		return manifest
	}
}

private struct AgentHandoffPackage: Codable, Equatable, Identifiable, Sendable {
	var id: UUID = UUID()
	let title: String
	let objective: String
	let context: String
	let projectPath: String?

	init(
		id: UUID = UUID(),
		title: String,
		objective: String,
		context: String = "",
		projectPath: String? = nil
	) {
		self.id = id
		self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
		self.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
		self.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
		self.projectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private enum CodingKeys: String, CodingKey { case title, objective, context, projectPath }
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
	/// Nil keeps journals written before completion acknowledgements compatible;
	/// those existing completions are intentionally presented as unseen updates.
	var completionAcknowledged: Bool?

	init(_ package: AgentHandoffPackage) {
		id = package.id
		title = package.title
		objective = package.objective
		context = package.context
		projectPath = package.projectPath
		state = .pending
	}

	var package: AgentHandoffPackage {
		.init(id: id, title: title, objective: objective, context: context, projectPath: projectPath)
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

	func append(
		request: AgentHandoffRequest,
		packages: [AgentHandoffPackage]
	) throws -> StoredAgentHandoff {
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
							handoff: HandoffPrompt.childRequest(package.package, input: input),
							projectPath: package.projectPath,
							isCompletionAcknowledged: package.completionAcknowledged ?? false
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

	func acknowledgeCompletions(of taskIDs: [UUID]) throws {
		let taskIDs = Set(taskIDs)
		guard !taskIDs.isEmpty else { return }
		try withLock {
			var handoffs = try load()
			var didChange = false
			for handoffIndex in handoffs.indices {
				for packageIndex in handoffs[handoffIndex].packages.indices {
					guard taskIDs.contains(handoffs[handoffIndex].packages[packageIndex].id),
						handoffs[handoffIndex].packages[packageIndex].state == .completed,
						handoffs[handoffIndex].packages[packageIndex].completionAcknowledged != true
					else { continue }

					handoffs[handoffIndex].packages[packageIndex].completionAcknowledged = true
					didChange = true
				}
			}
			if didChange {
				try save(handoffs)
			}
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
		try update(handoffID: handoffID, packageID: packageID) {
			$0.state = .completed
			$0.completionAcknowledged = false
		}
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
				let wasIncorrectlyMarkedFailedAfterCompletion = package.state == .failed
					&& package.failure == AgentHandoffError.launchFailed("Codex child").localizedDescription
				guard package.state == .running || package.state == .registered || package.state == .threadCreated
					|| wasIncorrectlyMarkedFailedAfterCompletion,
					let threadID = package.threadID,
					let terminalState = terminalState(forCodexThread: threadID, createdAt: handoffs[handoffIndex].createdAt)
				else { continue }

				handoffs[handoffIndex].packages[packageIndex].state = terminalState.state
				handoffs[handoffIndex].packages[packageIndex].failure = terminalState.failure
				if terminalState.state == .completed {
					handoffs[handoffIndex].packages[packageIndex].completionAcknowledged = false
				}
				didChange = true
			}
		}
		return didChange
	}

	private func terminalState(forCodexThread threadID: String, createdAt: Date) -> (state: AgentHandoffPackageState, failure: String?)? {
		guard let codexHome = CodexProjectCatalogLocation.cachedHomeDirectory(fileManager: fileManager) else {
			return nil
		}
		let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
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
			guard let contents = try? String(contentsOf: sessionURL, encoding: .utf8) else { continue }
			// Codex writes bookkeeping records after a terminal task event, so the
			// final JSONL line is not necessarily the lifecycle result. Walk backward
			// to the newest terminal event instead.
			for line in contents.split(separator: "\n").reversed() {
				guard let data = line.data(using: .utf8),
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
						"required": ["title", "objective", "context", "projectPath"],
						"properties": [
							"title": ["type": "string"],
							"objective": ["type": "string"],
							"context": ["type": "string"],
							"projectPath": ["type": "string"],
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
	private var didNotifyLaunch = false

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

	func takeLaunchNotification() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !didNotifyLaunch else { return false }
		didNotifyLaunch = true
		return true
	}

	var isFinished: Bool {
		lock.lock()
		defer { lock.unlock() }
		return finished
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
		reasoningEffort: RefinementReasoningEffort,
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
					var turnParams: [String: Any] = [
						"threadId": id,
						"input": inputItems,
					]
					if reasoningEffort != .none {
						turnParams["effort"] = reasoningEffort.rawValue
					}
					send([
						"id": 3,
						"method": "turn/start",
						"params": turnParams,
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
							// `turn/start` does not provide a stable progress boundary: some
							// app-server versions respond only after the entire turn ends. The
							// canonical thread already exists and the turn has been sent, so
							// report it as launched now.
							if runState.takeLaunchNotification() {
								onRegistered(id)
							}
						} catch {
							finish(.failure(error))
						}
					case 3:
						break
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
					// A completed turn intentionally stops the app-server process in
					// `finish`. Do not overwrite that terminal completion as a failure.
					guard !runState.isFinished else { return }
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
		workspace: AgentHandoffWorkspace.SecurityScopedDirectory,
		yield: @escaping @Sendable (AgentHandoffEvent) -> Void
	) async throws {
		// Keep the security scope alive through the coordinator launch and session
		// lookup. Passing only the URL would let ARC release the bookmark before
		// Claude Code receives the authorized working directory.
		defer { _ = workspace }
		let workspaceURL = workspace.root
		let executable = try executable(named: "claude")
		try await ClaudeHandoffSupport.preflight(executable: executable, workspace: workspaceURL)

		let token = UUID().uuidString.lowercased()
		let name = "Octo handoff \(token)"
		let screenshotURL = try AgentHandoffWorkspace.persistClaudeScreenshot(
			for: request,
			in: workspaceURL,
			handoffToken: token
		)
		var nativeSessionMayExist = false
		defer {
			if !nativeSessionMayExist, let screenshotURL {
				ClaudeHandoffArtifacts.removeFailedLaunchInput(at: screenshotURL, in: workspaceURL)
			}
		}
		let arguments = ClaudeHandoffCommand.coordinatorLaunchArguments(
			name: name,
			modelID: request.modelID,
			reasoningEffort: request.reasoningEffort,
			coordinatorInstruction: HandoffPrompt.claudeCoordinatorInstruction(token: token),
			userRequest: HandoffPrompt.userRequest(request, screenshotPath: screenshotURL?.path)
		)

		yield(.coordinatorSubmitted)
		let result = try await runProcess(
			executable: executable,
			arguments: arguments,
			currentDirectoryURL: workspaceURL
		)
		guard result.status == 0 else { throw AgentHandoffError.launchFailed("Claude") }
		// A successful `--bg` call transfers ownership of the prompt and its file
		// reference to Claude Code. Retain that exact input even if subsequent
		// session discovery fails, because the background task can still be live.
		nativeSessionMayExist = true

		let coordinatorID: String
		if let returnedID = uuid(in: result.output) {
			coordinatorID = returnedID
		} else {
			coordinatorID = try await findClaudeAgent(named: name, executable: executable, workspace: workspaceURL)
		}
		yield(.coordinatorStarted(.claude(coordinatorID)))

		let children = (try? await findClaudeAgents(
			withNamePrefix: "Octo handoff child \(token)",
			executable: executable,
			workspace: workspaceURL
		)) ?? []
		yield(.tasksFound(children.count))
		for (offset, childID) in children.enumerated() {
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
			arguments: ClaudeHandoffCommand.agentListArguments(workspace: workspace),
			currentDirectoryURL: workspace
		)
		guard result.status == 0 else { return [] }
		let root = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
		return AgentJSON.findIDs(in: root, matchingNamePrefix: name)
	}
}

/// The supported Claude Code command contract for an Octo handoff. Background
/// sessions appear in Claude Code Agent View; Claude Desktop does not provide a
/// route for importing those local Agent View sessions.
enum ClaudeHandoffCommand {
	static func coordinatorLaunchArguments(
		name: String,
		modelID: String?,
		reasoningEffort: RefinementReasoningEffort,
		coordinatorInstruction: String,
		userRequest: String
	) -> [String] {
		var arguments = [
			"--bg",
			"--name", name,
			"--append-system-prompt", coordinatorInstruction,
			userRequest,
		]
		if let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
			arguments.insert(contentsOf: ["--model", modelID], at: 0)
		}
		if reasoningEffort != .none {
			arguments.insert(contentsOf: ["--effort", reasoningEffort.rawValue], at: 0)
		}
		return arguments
	}

	static func agentListArguments(workspace: URL) -> [String] {
		["agents", "--json", "--all", "--cwd", workspace.path]
	}

	static func attachArguments(sessionID: String) -> [String] {
		["attach", sessionID]
	}
}

/// Agent View is the only supported surface for locally launched background
/// sessions. This performs read-only checks before writing a screenshot or
/// launching a coordinator, so unsupported environments fail without an
/// Octo-created Claude task or orphaned local input.
enum ClaudeHandoffSupport {
	static func preflight(executable: URL, workspace: URL) async throws {
		let versionResult = try await runProcess(
			executable: executable,
			arguments: ["--version"],
			currentDirectoryURL: workspace
		)
		guard versionResult.status == 0, supportsAgentView(versionOutput: versionResult.output) else {
			throw AgentHandoffError.claudeAgentViewUnavailable
		}

		let authenticationResult = try await runProcess(
			executable: executable,
			arguments: ["auth", "status"],
			currentDirectoryURL: workspace
		)
		guard authenticationResult.status == 0, isAuthenticated(statusOutput: authenticationResult.output) else {
			throw AgentHandoffError.claudeAuthenticationRequired
		}

		let agentsResult = try await runProcess(
			executable: executable,
			arguments: ClaudeHandoffCommand.agentListArguments(workspace: workspace),
			currentDirectoryURL: workspace
		)
		guard agentsResult.status == 0,
			let json = try? JSONSerialization.jsonObject(with: Data(agentsResult.output.utf8)),
			json is [Any] || json is [String: Any]
		else { throw AgentHandoffError.claudeAgentViewUnavailable }
	}

	static func supportsAgentView(versionOutput: String) -> Bool {
		guard let version = version(in: versionOutput) else { return false }
		return version.major > 2
			|| (version.major == 2 && (version.minor > 1 || (version.minor == 1 && version.patch >= 139)))
	}

	static func isAuthenticated(statusOutput: String) -> Bool {
		guard let root = try? JSONSerialization.jsonObject(with: Data(statusOutput.utf8)) as? [String: Any] else {
			return false
		}
		return root["loggedIn"] as? Bool == true
	}

	private static func version(in output: String) -> (major: Int, minor: Int, patch: Int)? {
		let pattern = "\\b(\\d+)\\.(\\d+)\\.(\\d+)\\b"
		guard let expression = try? NSRegularExpression(pattern: pattern),
			let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
			let majorRange = Range(match.range(at: 1), in: output),
			let minorRange = Range(match.range(at: 2), in: output),
			let patchRange = Range(match.range(at: 3), in: output),
			let major = Int(output[majorRange]),
			let minor = Int(output[minorRange]),
			let patch = Int(output[patchRange])
		else { return nil }
		return (major, minor, patch)
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

enum HandoffPrompt {
	private static let urlPattern = #"(?i)\b(?:(?:https?://)|(?:www\.))?(?:(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,})(?::\d{1,5})?(?:/[^\s<>\[\]{}()\"']*)?(?:\?[^\s<>\[\]{}()\"']*)?(?:#[^\s<>\[\]{}()\"']*)?"#
	private static let urlTrailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")

	static let codexChildInstruction = """
	You own one bounded Agent Handoff work package. First discover only the relevant configured native tools, skills, plugins, and MCP servers in the user's normal environment. If your package context lists source URLs to research, research those URLs yourself as needed for the bounded objective; URLs are research targets, not pre-researched findings. Then execute this package under the user's ordinary approval rules. Do not add a Nomen dependency or a custom discovery bridge. Do not delegate, split, or broaden the package.
	"""

	static let workPackagePlanningGuidance = """
	Respect user-provided manual handoff boundaries. The paired, case-insensitive markers `handoff start`/`handoff end` and `task start`/`task end` delimit manual work-package blocks. Create one separate work package for each marked block and never merge work across those boundaries. Keep all related steps, sub-tasks, and implementation details inside a marked block together unless the user creates another marked block inside it.

	When no explicit markers define boundaries, default to the fewest cohesive master work packages necessary. Related steps, sub-tasks, and implementation details normally belong in one master package; lists, conjunctions, and several requested actions are not themselves split signals. Split only genuinely distinct, independent work streams. When separation is unclear, keep work together and expect the user to state a separation explicitly.

	Before splitting, cleanly extract every URL from all source information. Treat a bare domain or path such as `example.com/docs` as a URL even when it has no `http://` or `https://` protocol, and normalize bare URLs with `https://`. Do not browse, fetch, evaluate, or otherwise research any URL yourself. Instead, put the relevant normalized URLs directly in each receiving work package's context under `Source URLs to research`; the child task, not the coordinator, owns that research.
	"""

	static func codexPlannerRequest(
		_ request: AgentHandoffRequest,
		projectCatalog: [CodexProjectCatalog.Project]
	) -> String {
		let encodedCatalog = (try? JSONEncoder().encode(projectCatalog))
			.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
		return """
		You are an ephemeral Agent Handoff planner. First use the current Codex project catalogue below to select the relevant existing project for each bounded work package. Then split the user's request into independently executable, bounded work packages. Do not inspect or choose tools, skills, plugins, or MCP servers. Do not execute package work and do not create tasks. Return only JSON matching the supplied schema. Each package needs a short title, an objective that can be completed by one agent, only the user context required for that objective, and the exact absolute projectPath from one catalogue entry. Never invent a path or select another directory. The full handoff input below, including any attached screenshot, is the same user context that each child task will receive.

		<codex_project_catalog>
		\(encodedCatalog)
		</codex_project_catalog>

		\(workPackagePlanningGuidance)

		\(sourceContext(
			transcript: request.transcript,
			selectedText: request.selectedText,
			screenContext: request.screenContext,
			screenAwareInputSource: request.screenAwareInputSource
		))
		"""
	}

	fileprivate static func childRequest(_ package: AgentHandoffPackage, input: StoredAgentHandoffInput) -> String {
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
		You are the Octo agent-handoff coordinator. Your only job is to split the user's request into independent, bounded work packages and start one new Claude Code Agent View background session for every package. Do not inspect configured tools, skills, plugins, MCP servers, the workspace, or project files. Do not perform any package's task work yourself.

		\(workPackagePlanningGuidance)

		Use Claude's native `claude --bg` sessions in the current working directory. Name each child `Octo handoff child \(token) <short title>`. Do not disable the child's normal configuration, skills, plugins, MCP servers, or approval rules. Pass this focused system instruction to every child with `--append-system-prompt`: first discover the relevant configured native tools, skills, plugins, and MCP servers in the user's normal environment; if its context lists source URLs to research, research those URLs itself as needed for its bounded objective; then execute only that objective under the user's ordinary approval rules. Do not add a Nomen dependency or custom discovery bridge. Give each child the complete original handoff input, its bounded objective, and the relevant `Source URLs to research` list. If the input includes a `screen_screenshot_path`, include that path verbatim so the child can inspect the user-provided screenshot when relevant. Do not create a local task manifest and do not ask Octo to create the child sessions.
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

		let sourceURLs = extractURLs(from: [transcript, selectedText, screenRecognizedText].compactMap { $0 })
		if !sourceURLs.isEmpty {
			sections.append("<source_urls>\nSource URLs to research:\n\(sourceURLs.joined(separator: "\n"))\n</source_urls>")
		}

		return sections.joined(separator: "\n\n")
	}

	private static func extractURLs(from sources: [String]) -> [String] {
		let expression = try? NSRegularExpression(pattern: urlPattern)
		var seen = Set<String>()
		var urls = [String]()

		for source in sources {
			let range = NSRange(source.startIndex..., in: source)
			for match in expression?.matches(in: source, range: range) ?? [] {
				guard let matchRange = Range(match.range, in: source) else { continue }
				let candidate = String(source[matchRange])
					.trimmingCharacters(in: urlTrailingPunctuation)
				guard !candidate.isEmpty else { continue }
				let normalized = candidate.range(of: #"(?i)^https?://"#, options: .regularExpression) == nil
					? "https://\(candidate)"
					: candidate
				guard seen.insert(normalized.lowercased()).inserted else { continue }
				urls.append(normalized)
			}
		}

		return urls
	}
}

private struct ProcessResult {
	let status: Int32
	let output: String
	let error: String
}

private func conciseProcessDiagnostic(_ error: String) -> String? {
	let lines = error
		.split(whereSeparator: \.isNewline)
		.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		.filter { !$0.isEmpty }
	guard let first = lines.first else { return nil }
	let limit = 300
	return first.count > limit ? String(first.prefix(limit)) + "…" : first
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
				let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
				continuation.resume(returning: .init(
					status: completed.terminationStatus,
					output: standardOutput,
					error: standardError
				))
			}
			do {
				try process.run()
			} catch {
				continuation.resume(throwing: AgentHandoffError.launchFailed(
					executable.lastPathComponent.capitalized,
					diagnostic: "macOS could not start the executable: \(error.localizedDescription)"
				))
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
			process.arguments = ["-a", "Terminal", "--args", agentExecutable.path]
				+ ClaudeHandoffCommand.attachArguments(sessionID: id)
			try? process.run()
		}
	}
}

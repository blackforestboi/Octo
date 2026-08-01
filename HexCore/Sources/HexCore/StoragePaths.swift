import Foundation

public extension URL {
	/// The Application Support root used by this installation.
	///
	/// Existing installations keep using their former sandbox container so an update that removes
	/// App Sandbox does not make settings, history, recordings, or downloaded models disappear.
	/// Fresh installations use the standard unsandboxed Application Support directory.
	static var hexApplicationSupportRoot: URL {
		get throws {
			let fm = FileManager.default
			let standardRoot = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)

			if let bundleIdentifier = Bundle.main.bundleIdentifier {
				let legacySandboxRoot = fm.homeDirectoryForCurrentUser
					.appendingPathComponent("Library/Containers", isDirectory: true)
					.appendingPathComponent(bundleIdentifier, isDirectory: true)
					.appendingPathComponent("Data/Library/Application Support", isDirectory: true)
				if fm.fileExists(atPath: legacySandboxRoot.path) {
					return legacySandboxRoot
				}
			}

			return standardRoot
		}
	}

	static var hexApplicationSupport: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try hexApplicationSupportRoot
			let hexDirectory = appSupport.appendingPathComponent("io.github.blackforestboi.Octo", isDirectory: true)
			try fm.createDirectory(at: hexDirectory, withIntermediateDirectories: true)
			return hexDirectory
		}
	}

	static func hexStoredFileURL(named fileName: String) -> URL {
		(try? hexApplicationSupport.appending(component: fileName))
			?? temporaryDirectory.appending(component: fileName)
	}

	static var hexModelsDirectory: URL {
		get throws {
			let modelsDirectory = try hexApplicationSupport.appendingPathComponent("models", isDirectory: true)
			try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
			return modelsDirectory
		}
	}

	/// Where FluidAudio (Parakeet) keeps its on-disk model caches.
	///
	/// FluidAudio writes to `<Application Support>/FluidAudio/Models/<variant>`,
	/// regardless of `XDG_CACHE_HOME`. We surface the installation's preferred
	/// Application Support location so existing sandboxed installs retain their
	/// downloaded models after updating.
	static var hexParakeetModelsDirectory: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try hexApplicationSupportRoot
			let dir = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			return dir
		}
	}
}

public extension FileManager {
	func removeItemIfExists(at url: URL) {
		guard fileExists(atPath: url.path) else { return }
		try? removeItem(at: url)
	}
}

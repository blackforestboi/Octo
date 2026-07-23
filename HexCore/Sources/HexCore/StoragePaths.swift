import Foundation

public extension URL {
	static var hexApplicationSupport: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let hexDirectory = appSupport.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
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
	/// FluidAudio writes to `<Application Support>/FluidAudio/Models/<variant>` in
	/// the sandboxed container, regardless of `XDG_CACHE_HOME`. We surface that
	/// location so "Show in Finder" can reveal Parakeet caches instead of the
	/// WhisperKit-only models directory.
	static var hexParakeetModelsDirectory: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
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

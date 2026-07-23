cask "octo" do
  version "0.2.11"
  sha256 :no_check  # Will be filled after first release

  url "https://github.com/blackforestboi/Octo/releases/download/v#{version}/Octo-#{version}.zip"
  name "Octo"
  desc "On-device voice-to-text for macOS"
  homepage "https://github.com/blackforestboi/Octo"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Octo.app"

  zap trash: [
    "~/Library/Application Support/io.github.blackforestboi.Octo",
    "~/Library/Caches/io.github.blackforestboi.Octo",
    "~/Library/Containers/io.github.blackforestboi.Octo",
    "~/Library/Preferences/io.github.blackforestboi.Octo.plist",
  ]
end

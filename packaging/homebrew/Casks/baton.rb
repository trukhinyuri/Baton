cask "baton" do
  # The release workflow (.github/workflows/bump-cask.yml) rewrites version and sha256 in the tap.
  version "1.0.0"
  sha256 "9afdb3fe0b2fac0877930532a197dbedad9568995b20a40d668392c5890bdb35"

  url "https://github.com/trukhinyuri/Baton/releases/download/v#{version}/Baton-v#{version}.zip"
  name "Baton"
  desc "Run one Claude Desktop window per account and hand sessions between them"
  homepage "https://github.com/trukhinyuri/Baton"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: :sonoma

  app "Baton.app"
  binary "#{appdir}/Baton.app/Contents/Helpers/baton"

  uninstall quit: "io.github.trukhinyuri.claudeprofiles"

  # Only the app's own preferences, caches and old app copies. Profiles/ (every window's sign-in), Backups/,
  # the launchers in ~/Applications/Claude Profiles, ~/.claude and Claude's own data are never removed.
  zap trash: [
    "~/Library/Application Support/Claude Profiles/AppBackups",
    "~/Library/Caches/io.github.trukhinyuri.claudeprofiles",
    "~/Library/Preferences/io.github.trukhinyuri.claudeprofiles.plist",
  ]
end

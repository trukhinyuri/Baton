cask "baton" do
  # The release workflow (its tap job, .github/workflows/bump-cask.yml) writes version and sha256 in the tap. The
  # sha256 here is a placeholder, never a real hash.
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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

  # Only the app's own preferences, caches and old app copies, in Baton's folder and in the Claude Profiles one of its
  # name before 1.0 (the bundle id kept that name). Profiles/ (every window's sign-in), Backups/, the launchers in
  # ~/Applications/Baton or ~/Applications/Claude Profiles, ~/.claude and Claude's own data are never removed.
  zap trash: [
    "~/Library/Application Support/Baton/AppBackups",
    "~/Library/Application Support/Claude Profiles/AppBackups",
    "~/Library/Caches/io.github.trukhinyuri.claudeprofiles",
    "~/Library/Preferences/io.github.trukhinyuri.claudeprofiles.plist",
  ]
end

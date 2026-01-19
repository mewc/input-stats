cask "typing-stats" do
  auto_updates true
  version "0.0.25"
  sha256 "c601a4ac0cfa7278e5ca5be756417745764143766f300334edc00a7b969fae90"

  url "https://github.com/rauchg/typing-stats/releases/download/v#{version}/TypingStats.zip"
  name "Typing Stats"
  desc "Track your daily keystroke statistics"
  homepage "https://github.com/rauchg/typing-stats"

  app "Typing Stats.app"

  postflight do
    system "xattr", "-cr", "#{appdir}/Typing Stats.app"
  end

  zap trash: [
    "~/Library/Application Support/TypingStats",
    "~/Library/Preferences/com.typing-stats.app.plist",
  ]
end

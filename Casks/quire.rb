# Homebrew cask（放在 tap 仓库里用：brew tap chaoyi-ai/quire && brew install --cask quire）
# 注意：App 目前只做 ad-hoc 签名、未公证——Gatekeeper 会拦，需要 `xattr -dr com.apple.quarantine /Applications/Quire.app`
# 或在 Finder 里右键打开。公证（Developer ID + notarytool）完成后去掉这段说明。版本与 sha256 由 scripts/release.sh 更新。
cask "quire" do
  version "0.8.0"
  sha256 "beef1104fb73e792be603bc63d168d2710dae7994b8478b9ce7cd3e372bf164d"

  url "https://github.com/chaoyi-ai/Quire/releases/download/v#{version}/Quire-#{version}.zip"
  name "Quire"
  desc "Fast, lightweight, native macOS Markdown reader and editor"
  homepage "https://github.com/chaoyi-ai/Quire"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Quire.app"

  zap trash: [
    "~/Library/Preferences/com.korako.quire.plist",
    "~/Library/Application Support/Quire",
    "~/Library/Caches/com.korako.quire",
  ]

  caveats <<~EOS
    Quire 尚未公证（需要 Developer ID），首次打开请：
      xattr -dr com.apple.quarantine "#{appdir}/Quire.app"
    或在 Finder 里右键 → 打开。
  EOS
end

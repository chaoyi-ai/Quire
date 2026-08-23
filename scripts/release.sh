#!/bin/zsh
# 发布：构建 App → 打包 zip → GitHub Release
# 用法：scripts/release.sh 0.1.0 [--draft]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?用法: scripts/release.sh <version> [--draft]}"
DRAFT="${2:-}"

# 版本号写入 Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" assets/Info.plist
BUILD=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" assets/Info.plist

echo "▸ CI 状态（main 最近一次完成的运行）"
CI=$(gh run list --branch main --status completed --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo unknown)
if [[ "$CI" != "success" && -z "${SKIP_CI_CHECK:-}" ]]; then
  echo "✗ main 上最近一次 CI 结论为 $CI（CI 用的 Xcode/Swift 比本机严格）。先修红再发；确要跳过：SKIP_CI_CHECK=1"; exit 1
fi
echo "▸ 测试"
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
echo "▸ 基准门禁"
scripts/bench.sh 1
echo "▸ 构建 App"
scripts/build_app.sh
ZIP="dist/Quire-$VERSION.zip"
rm -f "$ZIP"
(cd dist && ditto -c -k --keepParent Quire.app "Quire-$VERSION.zip")
shasum -a 256 "$ZIP" | tee "dist/Quire-$VERSION.zip.sha256"

# Homebrew cask：版本号与 sha256 跟着走（放到 tap 仓库后 brew 才能用）
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 .*/  sha256 \"$SHA\"/" Casks/quire.rb

echo "▸ 提交版本号 + 打 tag"
git add assets/Info.plist Casks/quire.rb
git commit -qm "release: $VERSION" || true
git tag -a "v$VERSION" -m "Quire $VERSION"
git push -q origin main --tags

echo "▸ GitHub Release"
NOTES=$(awk "/^## $VERSION/{flag=1;next}/^## /{flag=0}flag" CHANGELOG.md)
gh release create "v$VERSION" "$ZIP" "dist/Quire-$VERSION.zip.sha256" --title "Quire $VERSION" --notes "$NOTES" ${DRAFT:+--draft}
echo "✓ 发布完成"

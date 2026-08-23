#!/bin/zsh
# 发布：构建 App → 打包 zip → GitHub Release
# 用法：scripts/release.sh 0.1.0 [--draft]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?用法: scripts/release.sh <version> [--draft]}"
DRAFT="${2:-}"

# 先做所有门禁，最后才改版本号 / 打 tag：中途失败不留下改过的 Info.plist
[[ -z "$(git status --porcelain)" ]] || { echo "✗ 工作区有未提交的改动，先提交"; exit 1 }
git rev-parse --abbrev-ref HEAD | grep -qx main || { echo "✗ 只在 main 上发布"; exit 1 }
git tag | grep -qx "v$VERSION" && { echo "✗ 标签 v$VERSION 已存在"; exit 1 }

echo "▸ CI 状态（必须是 HEAD 这一个提交的运行）"
HEAD_SHA=$(git rev-parse HEAD)
git fetch -q origin main
[[ "$(git rev-parse origin/main)" == "$HEAD_SHA" ]] || { echo "✗ HEAD 还没推到 origin/main（或落后于它），CI 跑的不是这个提交"; exit 1 }
CI=$(gh run list --commit "$HEAD_SHA" --limit 1 --json status,conclusion --jq '.[0] | "\(.status)/\(.conclusion)"' 2>/dev/null || echo unknown)
if [[ "$CI" != "completed/success" && -z "${SKIP_CI_CHECK:-}" ]]; then
  echo "✗ 提交 ${HEAD_SHA:0:7} 的 CI 状态为 $CI（CI 用的 Xcode/Swift 比本机严格）。等它绿了再发；确要跳过：SKIP_CI_CHECK=1"; exit 1
fi
echo "▸ 测试"
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
echo "▸ 基准门禁"
scripts/bench.sh 1
# 版本号写入 Info.plist（门禁都过了才改）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" assets/Info.plist
BUILD=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" assets/Info.plist
echo "▸ 构建 App（含隔离 .build 的冒烟测试）"
scripts/build_app.sh
ZIP="dist/Quire-$VERSION.zip"
rm -f "$ZIP"
(cd dist && ditto -c -k --keepParent Quire.app "Quire-$VERSION.zip")
shasum -a 256 "$ZIP" | tee "dist/Quire-$VERSION.zip.sha256"

# Homebrew cask：版本号与 sha256 跟着走（放到 tap 仓库后 brew 才能用）
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 .*/  sha256 \"$SHA\"/" Casks/quire.rb

NOTES=$(awk "/^## $VERSION/{flag=1;next}/^## /{flag=0}flag" CHANGELOG.md)
[[ -n "$NOTES" ]] || { echo "✗ CHANGELOG.md 里没有 \"## $VERSION\" 段落"; git checkout -- assets/Info.plist Casks/quire.rb; exit 1 }

echo "▸ 提交版本号 + 打 tag"
git add assets/Info.plist Casks/quire.rb
git commit -qm "release: $VERSION" || true
git tag -a "v$VERSION" -m "Quire $VERSION"
git push -q origin main --tags

echo "▸ GitHub Release"
if ! gh release create "v$VERSION" "$ZIP" "dist/Quire-$VERSION.zip.sha256" --title "Quire $VERSION" --notes "$NOTES" ${DRAFT:+--draft}; then
  echo "✗ gh release create 失败。标签已推送；重试：gh release create v$VERSION $ZIP dist/Quire-$VERSION.zip.sha256 --title \"Quire $VERSION\" --notes-file <(echo \"\$NOTES\")"; exit 1
fi
echo "✓ 发布完成"

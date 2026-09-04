#!/bin/zsh
# 生成 App Intents（Shortcuts 动作）元数据：Metadata.appintents → 放进 Quire.app/Contents/Resources
# Xcode 会在构建时自动做这步；纯 SwiftPM 没有，所以这里手动：
#   1. swiftc -typecheck 整个 Quire 模块，带 -emit-const-values-path 抽出 AppIntent 等协议的静态常量
#   2. appintentsmetadataprocessor 把它编成 Metadata.appintents
# 用法：scripts/appintents_metadata.sh <config> <App.app>
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
APP=${2:-dist/Quire.app}
ARCH=$(uname -m); [ "$ARCH" = "arm64" ] || ARCH=x86_64
B=".build/${ARCH}-apple-macosx/$CONFIG"
WORK=".build/appintents"
rm -rf "$WORK"; mkdir -p "$WORK"
# 工具链以 xcode-select 选中的为准（CI 上 /Applications/Xcode.app 可能是另一个版本）
TOOLCHAIN="$(cd "$(dirname "$(xcrun --find swiftc)")/../.." && pwd)"
PROTOS_SRC="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"
if [ -f "$PROTOS_SRC" ]; then
  # 编译器要的是纯数组格式
  python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1]))['constValueProtocols'], open(sys.argv[2],'w'))" "$PROTOS_SRC" "$WORK/protocols.json"
else
  # Xcode 16.x 没有这个文件（26 才有）；协议名单很稳定，内置一份兜底，并把这件事说出来
  echo "appintents: 工具链里没有 $PROTOS_SRC，用脚本内置的协议名单"
  cat > "$WORK/protocols.json" <<'JSON'
["AnyResolverProviding","AppEntity","AppEnum","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicOptionsProvider","EntityQuery","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]
JSON
fi

args=()
for m in $(find "$B" .build/checkouts -name module.modulemap 2>/dev/null | grep -v "Tests\|QuickLook\|qtmp"); do args+=(-Xcc -fmodule-map-file=$m); done
SDK="$(xcrun --show-sdk-path --sdk macosx)"
swiftc -typecheck -wmo -swift-version 6 -module-name Quire -target "${ARCH}-apple-macos14.0" -sdk "$SDK" \
  -I "$B/Modules" -Xcc -I.build/checkouts/swift-cmark/src/include -Xcc -I.build/checkouts/swift-cmark/extensions/include "${args[@]}" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" \
  -emit-const-values-path "$WORK/Quire.swiftconstvalues" \
  $(find Sources/Quire -name '*.swift') "$B/Quire.build/DerivedSources/resource_bundle_accessor.swift" 2>&1 | grep -E "error:" && { echo "appintents: typecheck 失败"; exit 1 } || true
[ -f "$WORK/Quire.swiftconstvalues" ] || { echo "appintents: 没有 const values"; exit 1 }

find Sources/Quire -name '*.swift' > "$WORK/sources.txt"   # 递归：Sidebar/ 等子目录也算
echo "$WORK/Quire.swiftconstvalues" > "$WORK/constvals.txt"
XCV=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}'); [ -n "$XCV" ] || XCV=16F18
set +e
PROC_OUT=$(xcrun appintentsmetadataprocessor --output "$WORK" --toolchain-dir "$TOOLCHAIN" --module-name Quire --sdk-root "$SDK" \
  --xcode-version "$XCV" --platform-family macOS --deployment-target 14.0 --target-triple "${ARCH}-apple-macos14.0" \
  --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/constvals.txt" --force --quiet-warnings 2>&1)
PROC_STATUS=$?
set -e
echo "$PROC_OUT" | grep -v "^20" || true
[ "$PROC_STATUS" -eq 0 ] || { echo "appintents: appintentsmetadataprocessor 退出码 $PROC_STATUS"; exit 1 }
[ -d "$WORK/Metadata.appintents" ] || { echo "appintents: 没生成 Metadata.appintents"; exit 1 }
grep -q '"OpenInQuireIntent"' "$WORK/Metadata.appintents/extract.actionsdata" || { echo "appintents: 元数据里没有动作"; exit 1 }
rm -rf "$APP/Contents/Resources/Metadata.appintents"
cp -R "$WORK/Metadata.appintents" "$APP/Contents/Resources/"
echo "✓ App Intents 元数据: $(ls "$APP/Contents/Resources/Metadata.appintents" | tr '\n' ' ')"

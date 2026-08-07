#!/bin/bash
# M6 发布流水线：archive → [Developer ID 重签] → [公证+装订] → DMG（Obsidian 式版式）→ 复核
#
# 用法：
#   Scripts/release.sh
#       无 Developer ID 证书时：archive + DMG（保留 archive 里的原签名，不公证）。
#       产物过不了别的机器的 Gatekeeper（首启需右键打开，见 README）。
#   Scripts/release.sh --identity "Developer ID Application: NAME (TEAMID)" --keychain-profile cof-notary
#       正式发布：重签（hardened runtime + timestamp）→ 公证 app → 装订
#       → DMG → 签 DMG → 公证 DMG → 装订 → Gatekeeper 评估。
#
# 前置（正式发布）：
#   1. keychain 里有 Developer ID Application 证书（security find-identity -v -p codesigning）
#   2. 公证凭证已存 profile：xcrun notarytool store-credentials cof-notary \
#        --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# 注意：DMG 版式那步用 AppleScript 控制 Finder，首次运行会弹「自动化」授权，需要点允许。
#
# ★ 整个工作区放在 iCloud 同步树之外（mktemp → /var/folders）。仓库在 ~/Documents
#   （桌面与文稿同步）：file provider 会在文件落盘后异步补打 FinderInfo/fileprovider
#   xattr，strict codesign 校验与公证都会拒（"…detritus not allowed"）。在同步树内
#   xattr -cr 是必输的竞赛——Day 12 实测：剥完校验刚过，hdiutil 捕获前又被打回。
#   唯一确定性修法是不在同步树里干活，只把最终 DMG 拷回仓库。
#   xattr -cr + 两道复核仍保留作纵深防御。
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

IDENTITY=""
PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)         IDENTITY="$2"; shift 2 ;;
    --keychain-profile) PROFILE="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$PROFILE" && -z "$IDENTITY" ]]; then
  echo "error: --keychain-profile 需要同时给 --identity（没有 Developer ID 签名的公证没有意义）" >&2
  exit 2
fi

SCHEME="CradleOfFilth"          # Xcode scheme（工程内部名，不外泄）
PRODUCT="Container Cradle"      # 公开产品名（app 文件名 / DMG 卷名）
DMG_BASENAME="ContainerCradle"  # DMG 文件名（无空格，便于 URL）
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cof-release.XXXXXX")"
ARCHIVE="$WORK/$SCHEME.xcarchive"
APP="$ARCHIVE/Products/Applications/$PRODUCT.app"
STAGING="$WORK/dmg-staging"
echo "工作区（非 iCloud 同步）：$WORK"

echo "==> [0/6] 隔离契约守卫（UI 回调的 @MainActor + F6 结构守卫 + compile fixture）"
"$REPO/Scripts/check-mainactor-callbacks.sh"

echo "==> [1/6] archive (Release)"
# ★ -derivedDataPath 指向本次 mktemp 工作区：**每次发版 archive 必然从零编译**。
#   不加它就用默认 DerivedData 根（与日常 Debug 构建同一个），archive 可能走增量——
#   而增量构建会把编译警告整个藏起来（v0.3.0 的 Sendable 警告就是这么活到发版前的）。
#   「上次 archive 报了警告」只能证明那一次它编译了那个文件，推不出每次都会。
ARCHIVE_LOG="$WORK/archive.log"
xcodebuild -project "$REPO/CradleOfFilth.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$WORK/DerivedData" archive -quiet 2>&1 | tee "$ARCHIVE_LOG"
test -d "$APP"

# 警告闸门。**绝不能写成 `xcodebuild … | grep warning` 当成功条件**——零警告时 grep 返回 1，
# 上面的 set -euo pipefail 会在「一切正常」时中止发版。所以先 tee 存盘，成功后再判读。
# 只数本仓库源码路径的诊断，排除工具链噪音（appintentsmetadataprocessor 那类）。
if grep -qE "^${REPO}/(CradleOfFilth|Packages)/.*warning:" "$ARCHIVE_LOG"; then
  echo "error: Release 构建带编译警告，发版中止。" >&2
  grep -E "^${REPO}/(CradleOfFilth|Packages)/.*warning:" "$ARCHIVE_LOG" | sed "s|^${REPO}/||" | sort -u >&2
  exit 1
fi
echo "    警告闸门通过（本仓库源码零警告，全量编译）"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")
DMG="$WORK/$DMG_BASENAME-$VERSION.dmg"
DMG_OUT="$REPO/build/release/$DMG_BASENAME-$VERSION.dmg"

if [[ -n "$IDENTITY" ]]; then
  echo "==> [2/6] Developer ID 重签（hardened runtime + timestamp）"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "==> [2/6] 跳过重签（未给 --identity，保留 archive 原签名）"
fi
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Authority=|Signature|TeamIdentifier=|flags=)" || true

if [[ -n "$PROFILE" ]]; then
  echo "==> [3/6] 公证 app + 装订"
  ditto -c -k --keepParent "$APP" "$WORK/$DMG_BASENAME.zip"
  xcrun notarytool submit "$WORK/$DMG_BASENAME.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
else
  echo "==> [3/6] 跳过公证（未给 --keychain-profile）"
fi

echo "==> [4/6] 打 DMG（版式：app 左、Applications 右、128px 图标）"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$PRODUCT.app"
xattr -cr "$STAGING/$PRODUCT.app"
codesign --verify --strict --deep "$STAGING/$PRODUCT.app"
ln -s /Applications "$STAGING/Applications"

RW_DMG="$WORK/rw.dmg"
hdiutil create -volname "$PRODUCT" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG" -quiet
hdiutil detach "/Volumes/$PRODUCT" -quiet 2>/dev/null || true
hdiutil attach "$RW_DMG" -noverify -noautoopen -quiet
osascript <<EOF
tell application "Finder"
  tell disk "$PRODUCT"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 880, 540}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "$PRODUCT.app" of container window to {170, 180}
    set position of item "Applications" of container window to {510, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync
sleep 2
hdiutil detach "/Volumes/$PRODUCT" -quiet
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" -quiet

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [[ -n "$PROFILE" ]]; then
  echo "==> [5/6] 公证 DMG + 装订 + Gatekeeper 评估"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -t exec -v "$STAGING/$PRODUCT.app"
else
  echo "==> [5/6] 跳过 DMG 公证与 Gatekeeper 评估（未给凭证）"
fi

echo "==> [6/6] DMG 复核（挂载 + 严格校验）"
MOUNT=$(mktemp -d)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
codesign --verify --strict --deep "$MOUNT/$PRODUCT.app"
hdiutil detach "$MOUNT" -quiet
trap - EXIT
echo "挂载复核 OK"

mkdir -p "$REPO/build/release"
cp "$DMG" "$DMG_OUT"
rm -rf "$WORK"

echo
echo "产物：$DMG_OUT"
du -h "$DMG_OUT" | cut -f1

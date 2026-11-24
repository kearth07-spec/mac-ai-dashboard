#!/bin/zsh
# ビルドして ~/Applications/Muscle.app を組み立ててから起動する。
# マイク・音声認識・画面収録の許可はアプリバンドル単位で記録されるため、素の実行ファイルでは使えない。
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/Muscle.app"

echo "ビルド中…（大きな更新のあとは数分かかります）"
swift build -c release

# 動いている古い版を止める（旧名 Orrery.app も）
pkill -f "Muscle.app/Contents/MacOS/Muscle" 2>/dev/null || true
pkill -f "Orrery.app/Contents/MacOS/Orrery" 2>/dev/null || true
# 止まりきる前に開くと「error -600」で開けないので、終わるまで待つ（最大5秒）
for _ in {1..25}; do
  pgrep -f "Muscle.app/Contents/MacOS/Muscle|Orrery.app/Contents/MacOS/Orrery" >/dev/null || break
  sleep 0.2
done
rm -rf "$HOME/Applications/Orrery.app"

mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Orrery" "$APP/Contents/MacOS/Muscle"
cp "AppResources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "AppResources/Orrery.icns" "$APP/Contents/Resources/Orrery.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 署名を固定する。アドホック署名だとビルドごとに別アプリ扱いになり、
# 画面収録などの許可が毎回外れてしまう。
if security find-certificate -c "Muscle Dev" >/dev/null 2>&1; then
  codesign --force --sign "Muscle Dev" "$APP" >/dev/null
else
  echo "メモ: 証明書 'Muscle Dev' が無いためアドホック署名にします（作り直すたびに許可が外れます）"
  codesign --force --sign - "$APP" >/dev/null
fi

echo "起動します: $APP"
# まれに開けないことがあるので、少し待ってからもう一度試す
open "$APP" 2>/dev/null || { sleep 1.5; open "$APP"; }

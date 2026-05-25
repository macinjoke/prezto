#!/usr/bin/env bash
#
# Docker OOM Watcher
#
# `docker events --filter event=oom` を購読し、コンテナが OOM kill された
# 瞬間に macOS の通知センターへ通知を出す。並列 worktree 開発時、Next.js dev
# (turbopack) コンテナが Docker Desktop のメモリ上限を超えてサイレントに殺される
# (Exit 0 + OOMKilled=true) ケースに即気付くための常駐スクリプト。
#
# 使い方:
#   ./oom-watcher.sh           # フォアグラウンドで動作確認
#   常駐は launchd 経由 (同ディレクトリの launchd.plist を参照)
#

set -euo pipefail

# docker CLI が無ければ起動できないので即終了
if ! command -v docker >/dev/null 2>&1; then
  echo "[oom-watcher] docker CLI が PATH に見つかりません" >&2
  exit 127
fi

# osascript は macOS 専用。Linux 等では実行不可
if ! command -v osascript >/dev/null 2>&1; then
  echo "[oom-watcher] osascript が見つかりません (本スクリプトは macOS 専用)" >&2
  exit 127
fi

# macOS 通知センターへ通知を表示する。
# 通知本文に表示する name / image をエスケープしてから AppleScript に渡す。
# 通知音は "Sosumi" (短く存在感のあるシステム音)。
notify() {
  local name="${1:-unknown}"
  local image="${2:-?}"

  # AppleScript 中のダブルクォートをエスケープ (二重起動防止のため安全側)
  local safe_name
  safe_name=$(printf '%s' "$name" | sed 's/"/\\"/g')
  local safe_image
  safe_image=$(printf '%s' "$image" | sed 's/"/\\"/g')

  osascript <<APPLESCRIPT
display notification "container: ${safe_name}\nimage: ${safe_image}" with title "🚨 Docker OOM killed" sound name "Sosumi"
APPLESCRIPT

  # launchd の StandardOutPath に流すための痕跡ログ (タイムスタンプ付き)
  printf '[oom-watcher] %s — %s (image: %s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$image"
}

echo "[oom-watcher] docker の oom イベント購読を開始します..."

# `docker events` は無限にブロックして JSON 行をストリームする。
# docker daemon が再起動するとここで exit する → launchd の KeepAlive で
# 自動的に再 spawn される想定。
docker events --filter event=oom --format '{{json .}}' | while IFS= read -r line; do
  # jq に依存したくないので python3 で JSON をパース。
  # name / image を tab 区切りで 1 行に出力する。
  parsed=$(printf '%s' "$line" | python3 -c '
import json, sys
try:
    evt = json.load(sys.stdin)
except Exception:
    sys.exit(0)
attrs = (evt.get("Actor") or {}).get("Attributes") or {}
name = attrs.get("name", "unknown")
image = attrs.get("image", "?")
print(f"{name}\t{image}")
') || continue

  name=$(printf '%s' "$parsed" | awk -F'\t' '{print $1}')
  image=$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')
  notify "$name" "$image"
done

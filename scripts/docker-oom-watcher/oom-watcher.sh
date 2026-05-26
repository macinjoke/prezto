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

# terminal-notifier は通知パネル(Alert)スタイルにできて閉じるまで残せる。
# brew install terminal-notifier で導入する想定。
if ! command -v terminal-notifier >/dev/null 2>&1; then
  echo "[oom-watcher] terminal-notifier が見つかりません (brew install terminal-notifier)" >&2
  exit 127
fi

# macOS 通知センターへ通知を表示する。
# 通知音は "Sosumi" (短く存在感のあるシステム音)。
# System Settings → Notifications → terminal-notifier を Alerts にすると
# クリックするまで通知パネルが残るようになる。
notify() {
  local name="${1:-unknown}"
  local image="${2:-?}"

  terminal-notifier \
    -title "🚨 Docker OOM killed" \
    -message "container: ${name}"$'\n'"image: ${image}" \
    -sound Sosumi \
    -group "docker-oom-watcher:${name}" \
    -ignoreDnD >/dev/null || true

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

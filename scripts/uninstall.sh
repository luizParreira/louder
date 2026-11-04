#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="io.github.luizparreira.Louder"

say() { printf '==> %s\n' "$*"; }

main() {
  if pgrep -x Louder >/dev/null 2>&1; then
    say "Quitting Louder"
    osascript -e 'tell application "Louder" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x Louder 2>/dev/null || true
  fi

  for dir in /Applications "$HOME/Applications"; do
    if [[ -d "$dir/Louder.app" ]]; then
      say "Removing $dir/Louder.app"
      if ! rm -rf "$dir/Louder.app" 2>/dev/null; then
        echo "warning: could not remove $dir/Louder.app; delete it manually" >&2
      fi
    fi
  done

  say "Removing preferences"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

  cat <<MSG

Louder has been removed.

If Louder still appears as a login item, check System Settings > General >
Login Items & Extensions.

To also reset the System Audio Recording permission, run:
  tccutil reset AudioCapture $BUNDLE_ID
MSG
}

main "$@"

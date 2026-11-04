#!/usr/bin/env bash
# Installs build/Louder.app the same way scripts/install.sh installs a release.
# LOUDER_INSTALL_DIR overrides the destination directory (used for testing).
set -euo pipefail

APP_NAME="Louder"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/build/$APP_NAME.app}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

is_running() { pgrep -x "$APP_NAME" >/dev/null 2>&1; }

quit_running() {
  is_running || return 0
  say "Quitting running $APP_NAME"
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    is_running || return 0
    sleep 0.5
  done
  pkill -x "$APP_NAME" || true
  sleep 1
}

pick_dest_dir() {
  if [[ -n "${LOUDER_INSTALL_DIR:-}" ]]; then
    mkdir -p "$LOUDER_INSTALL_DIR"
    echo "$LOUDER_INSTALL_DIR"
    return
  fi
  local dir
  for dir in /Applications "$HOME/Applications"; do
    if [[ -d "$dir/$APP_NAME.app" && -w "$dir" ]]; then
      echo "$dir"
      return
    fi
  done
  if [[ -w /Applications ]]; then
    echo /Applications
  else
    mkdir -p "$HOME/Applications"
    echo "$HOME/Applications"
  fi
}

swap_in() {
  local new="$1" dest="$2" backup="$3"
  if [[ -e "$dest" ]]; then
    mv "$dest" "$backup" || return 1
  fi
  if ! mv "$new" "$dest"; then
    if [[ -e "$backup" ]]; then mv "$backup" "$dest"; fi
    return 1
  fi
  rm -rf "$backup"
}

main() {
  [[ -d "$SRC" ]] || die "$SRC not found; run 'make app' first."

  quit_running

  local dest_dir dest
  dest_dir="$(pick_dest_dir)"
  dest="$dest_dir/$APP_NAME.app"

  say "Installing to $dest"
  STAGE="$(mktemp -d "$dest_dir/.$APP_NAME-install.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  ditto "$SRC" "$STAGE/new.app" || die "copy failed; existing $APP_NAME was left in place."
  xattr -dr com.apple.quarantine "$STAGE/new.app" 2>/dev/null || true
  swap_in "$STAGE/new.app" "$dest" "$STAGE/old.app" || die "could not replace $dest."

  say "Installed $dest"
}

main

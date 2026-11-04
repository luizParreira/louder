#!/usr/bin/env bash
set -euo pipefail

REPO="luizParreira/louder"
APP_NAME="Louder"
PROCESS_NAME="Louder"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

pick_dest_dir() {
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
    say "/Applications is not writable; installing to $HOME/Applications" >&2
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
  [[ "$(uname -s)" == "Darwin" ]] || die "Louder only runs on macOS."

  MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
  if (( MAJOR < 15 )); then
    die "Louder requires macOS 15 or later (found $(sw_vers -productVersion))."
  fi

  if [[ -n "${LOUDER_VERSION:-}" ]]; then
    VERSION="$LOUDER_VERSION"
    [[ "$VERSION" == v* ]] || VERSION="v$VERSION"
    BASE="https://github.com/$REPO/releases/download/$VERSION"
    say "Installing Louder $VERSION"
  else
    BASE="https://github.com/$REPO/releases/latest/download"
    say "Installing the latest Louder release"
  fi

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" "${STAGE:-}"' EXIT

  say "Downloading Louder.zip"
  curl -fsSL "$BASE/Louder.zip" -o "$TMP/Louder.zip" || die "download failed: $BASE/Louder.zip"
  curl -fsSL "$BASE/Louder.zip.sha256" -o "$TMP/Louder.zip.sha256" || die "download failed: $BASE/Louder.zip.sha256"

  say "Verifying checksum"
  EXPECTED="$(awk '{print $1}' "$TMP/Louder.zip.sha256")"
  ACTUAL="$(shasum -a 256 "$TMP/Louder.zip" | awk '{print $1}')"
  if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    die "checksum mismatch (expected $EXPECTED, got $ACTUAL). Nothing was installed."
  fi

  say "Unpacking"
  ditto -x -k "$TMP/Louder.zip" "$TMP/extracted"
  [[ -d "$TMP/extracted/$APP_NAME.app" ]] || die "archive does not contain $APP_NAME.app"

  if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    say "Quitting running Louder"
    osascript -e 'tell application "Louder" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
      pkill -x "$PROCESS_NAME" || true
      sleep 1
    fi
  fi

  DEST_DIR="$(pick_dest_dir)"
  DEST="$DEST_DIR/$APP_NAME.app"

  say "Installing to $DEST"
  STAGE="$(mktemp -d "$DEST_DIR/.$APP_NAME-install.XXXXXX")"
  ditto "$TMP/extracted/$APP_NAME.app" "$STAGE/new.app" || die "copy failed; any existing $APP_NAME was left in place."
  xattr -dr com.apple.quarantine "$STAGE/new.app" 2>/dev/null || true
  swap_in "$STAGE/new.app" "$DEST" "$STAGE/old.app" || die "could not replace $DEST."

  say "Opening Louder"
  open "$DEST"

  cat <<MSG

Louder is installed at $DEST.
Look for it in the menu bar. On first use, allow "System Audio Recording" in
System Settings > Privacy & Security > Screen & System Audio Recording.
MSG
}

main "$@"

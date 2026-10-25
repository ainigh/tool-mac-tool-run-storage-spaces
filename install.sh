#!/bin/bash
# Installs (or updates: run it again) Storage Spaces into ~/Applications, then opens it.
#
#   brew install gh && gh auth login        (the first time only)
#   gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-run-storage-spaces/contents/install.sh | bash
#
# The repository may be private, so everything comes through gh, signed in to GitHub. Run as a
# file (bash install.sh) it sets gh up itself if it's missing, and it asks you to sign in when gh
# can't see the repository. It takes the latest release GitHub built. If there isn't one (or
# STORAGE_FROM_SOURCE=1), it downloads the source of main (STORAGE_BRANCH=name for another branch)
# and builds it here with Apple's command line tools. Running it again is safe: it replaces the
# app and keeps every space (~/Desktop/STORAGE-SPACES) as it is.
set -euo pipefail

REPO="ainigh/tool-mac-tool-run-storage-spaces"
BRANCH="${STORAGE_BRANCH:-main}"
APPS="$HOME/Applications"
NAME="StorageSpaces"

say() { printf '\n\033[1m👉 %s\033[0m\n' "$*"; }
ok() { printf '✅ %s\n' "$*"; }
die() { printf '\n\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

say "Installing Storage Spaces: the latest build into $APPS, then open it (every space stays as it is)"

# gh, signed in ------------------------------------------------------------------------------
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do if [[ -x "$b" ]]; then eval "$("$b" shellenv)"; fi; done
if ! command -v gh >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Needs Homebrew first: https://brew.sh — install it, then run this again."
  say "Installing gh (GitHub's command line tool)"
  brew install gh
fi
if ! gh api "repos/$REPO" --silent >/dev/null 2>&1; then
  say "Sign in to GitHub with an account that can see $REPO (a browser window opens)"
  # Piped into bash, this script is bash's input: the sign-in reads the keyboard instead.
  gh auth login --web --git-protocol https -h github.com </dev/tty \
    || die "Signing in didn't finish. Run  gh auth login  in Terminal, then run this again."
  gh api "repos/$REPO" --silent >/dev/null 2>&1 || die "That account can't open $REPO. Sign in with one that can (gh auth login), then run this again."
fi

tmp="$(mktemp -d)"
previous="$APPS/.$NAME-previous.app"
# Set while the app that was here is parked at $previous: if anything fails then, it goes back.
parked=0
was_running=0
# shellcheck disable=SC2329  # run by the trap
cleanup() {
  local status=$?
  if [[ "$parked" == 1 && -d "$previous" ]]; then
    rm -rf "$APPS/$NAME.app"
    if mv "$previous" "$APPS/$NAME.app"; then
      printf '\n\033[31m❌ %s\033[0m\n' "The install didn't finish, so the app you had is back as it was." >&2
      if [[ "$was_running" == 1 ]]; then open "$APPS/$NAME.app" || true; fi
    fi
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT

# the app: GitHub's build, else built here -----------------------------------------------------
app=""
if [[ "${STORAGE_FROM_SOURCE:-0}" != 1 && "$BRANCH" == main ]]; then
  say "Downloading the latest release"
  if gh release download --repo "$REPO" --pattern "$NAME.zip" --dir "$tmp" 2>/dev/null; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  else
    echo "   No release yet: building it here instead (a minute or two)."
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run  xcode-select --install  then run this again."
  sha="$(gh api "repos/$REPO/commits/$BRANCH" --jq .sha)" || die "Couldn't find the branch $BRANCH."
  say "Downloading the source ($BRANCH, ${sha:0:7})"
  mkdir -p "$tmp/src"
  gh api "repos/$REPO/tarball/$sha" > "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components 1
  say "Building (a minute or two)"
  (cd "$tmp/src" && VERSION="0.1-${sha:0:7}" COMMIT="$sha" BRANCH="$BRANCH" UNIVERSAL=0 scripts/build-app.sh)
  app="$tmp/src/build/$NAME.app"
fi

# install and open -----------------------------------------------------------------------------
# The app that was here is kept until the new one is seen running: if the new one quits straight
# away, the old one goes back and opens again, so an install never leaves you without it.
say "Installing into $APPS"
[[ -d "$app" ]] || die "The download didn't hold $NAME.app. Run this again; if it happens twice, try STORAGE_FROM_SOURCE=1."
if pkill -x "$NAME" 2>/dev/null; then
  was_running=1
  # Wait for it to quit (up to 5 seconds), then make sure.
  for _ in $(seq 1 50); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
  if pgrep -x "$NAME" >/dev/null; then pkill -9 -x "$NAME" 2>/dev/null || true; sleep 0.5; fi
  echo "   Closed the running copy (it reopens in a moment)."
fi
mkdir -p "$APPS"
# An install stopped dead (the Mac lost power) while the app was parked: that copy is the one to keep.
if [[ -d "$previous" && ! -d "$APPS/$NAME.app" ]]; then mv "$previous" "$APPS/$NAME.app"; fi
rm -rf "$previous"
replaced=0
old_version=""
if [[ -d "$APPS/$NAME.app" ]]; then
  old_version="$(defaults read "$APPS/$NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
  mv "$APPS/$NAME.app" "$previous"
  parked=1
  replaced=1
fi
# Crash reports written after this are the new app's.
touch "$tmp/installed"
ditto "$app" "$APPS/$NAME.app"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
version="$(defaults read "$APPS/$NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
if [[ "$replaced" == 1 ]]; then ok "Replaced $old_version with $version"; else ok "Installed $version"; fi

open "$APPS/$NAME.app"

# Still running a few seconds on: it started.
started=0
for _ in 1 2 3 4 5 6; do
  sleep 1
  # Its path matched as it is (pgrep -f would read characters such as + or ( in it as a pattern).
  if ps -axo command= | P="$APPS/$NAME.app/Contents/MacOS/$NAME" awk 'index($0, ENVIRON["P"]) == 1 { f = 1 } END { exit !f }'; then started=1; else started=0; fi
done
if [[ "$started" == 1 ]]; then
  parked=0
  rm -rf "$previous"
  say "Done ($version). Look for Storage Spaces' icon (three stacked squares) in the menu bar: click it, then Open Storage Spaces."
  echo "   Everything it keeps is in ~/Desktop/STORAGE-SPACES; the apps reach it at http://127.0.0.1:8771."
  echo "   Not there? The menu bar may be full (behind the camera notch): quit an icon or two, or hold ⌘ and drag some away."
  echo "   To update later, run the same command again."
  exit 0
fi

# Only a crash report written since the install is about this app.
crash="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -iname "*$NAME*" -newer "$tmp/installed" 2>/dev/null | head -1 || true)"
failed="$APPS/$NAME.app"
if [[ -d "$previous" ]]; then
  # The new app that quit is kept beside the old one, to look into.
  failed="$APPS/.$NAME-failed.app"
  rm -rf "$failed"
  mv "$APPS/$NAME.app" "$failed"
  mv "$previous" "$APPS/$NAME.app"
  parked=0
  open "$APPS/$NAME.app"
  printf '\n\033[31m❌ %s\033[0m\n' "The new $NAME ($version) quit as soon as it opened, so the one you had ($old_version) is back and open again." >&2
else
  printf '\n\033[31m❌ %s\033[0m\n' "$NAME $version quit as soon as it opened." >&2
fi
if [[ -n "$crash" ]]; then echo "   What went wrong is in $crash" >&2; fi
echo "   To see it happen: $failed/Contents/MacOS/$NAME" >&2
exit 1

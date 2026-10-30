#!/bin/zsh
# Ripple Drive installer: your Google Drive as a disk on your Mac.
#   zsh install.sh                   install (or update) everything, sign in, start the drive
#   zsh install.sh --no-signin       skip the Google sign-in (run ripple-drive-signin later)
#   zsh install.sh --no-start        install only: don't start the drive or the app
#   zsh install.sh --update-rclone   also replace rclone with the latest release
# Everything goes into your home folder: ~/.local/bin (scripts + rclone), ~/Applications (the app),
# ~/Library/LaunchAgents (start at login). Only fuse-t's own installer asks for your Mac password.
set -e
cd "${0:A:h}"
SIGNIN=1; START=1; NEW_RCLONE=0
for a in "$@"; do
  case $a in
    --no-signin) SIGNIN=0 ;;
    --no-start) START=0 ;;
    --update-rclone) NEW_RCLONE=1 ;;
    -h|--help) sed -n '2,9p' "$0" | cut -c3-; exit 0 ;;
    *) print "Unknown option: $a (try --help)"; exit 1 ;;
  esac
done

BIN="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/Ripple Drive.app"
FUSE_T="/usr/local/lib/libfuse-t.dylib"
MNT="$HOME/RippleDrive"
DOMAIN="gui/$(id -u)"
step() { print "\n\033[1m$1\033[0m" }
fail() { print "\n\033[31m$1\033[0m"; exit 1 }

step "1/7 Checking this Mac"
[[ "$(uname -m)" == arm64 ]] || fail "Ripple Drive needs an Apple Silicon Mac."
ver=$(sw_vers -productVersion)
(( ${ver%%.*} >= 26 )) || fail "Ripple Drive needs macOS 26 or later (it uses Apple's FSKit). This Mac has $ver."
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  fail "Apple's Command Line Tools are needed to build the app. Finish the install window that just opened, then run zsh install.sh again."
fi
print "OK: macOS $ver, Apple Silicon, Command Line Tools"

step "2/7 fuse-t (lets macOS show the drive as a disk)"
if [[ ! -e "$FUSE_T" ]]; then
  command -v brew >/dev/null || fail "Install fuse-t first (https://www.fuse-t.org), then run zsh install.sh again."
  print "Installing fuse-t with Homebrew (it may ask for your Mac password)..."
  brew install macos-fuse-t/homebrew-cask/fuse-t
  [[ -e "$FUSE_T" ]] || fail "fuse-t didn't install. Try: brew install macos-fuse-t/homebrew-cask/fuse-t"
fi
print "OK: fuse-t"

step "3/7 rclone (talks to Google Drive)"
# The official build: Homebrew's rclone can't mount on macOS.
if [[ ! -x "$BIN/rclone" || $NEW_RCLONE == 1 ]]; then
  rv=$(curl -fsSL https://downloads.rclone.org/version.txt | awk '{print $2}')
  [[ $rv == v* ]] || fail "Couldn't read rclone's latest version from downloads.rclone.org."
  zip="rclone-$rv-osx-arm64.zip"
  tmp=$(mktemp -d)
  print "Downloading rclone $rv..."
  curl -fL --progress-bar -o "$tmp/$zip" "https://downloads.rclone.org/$rv/$zip"
  curl -fsSL -o "$tmp/SHA256SUMS" "https://downloads.rclone.org/$rv/SHA256SUMS"
  want=$(awk -v z="$zip" '$2 == z {print $1}' "$tmp/SHA256SUMS")
  got=$(shasum -a 256 "$tmp/$zip" | awk '{print $1}')
  if [[ -z $want || $want != $got ]]; then rm -rf "$tmp"; fail "The rclone download didn't match its checksum, so nothing was installed."; fi
  unzip -q "$tmp/$zip" -d "$tmp"
  mkdir -p "$BIN"
  mv -f "$tmp/${zip%.zip}/rclone" "$BIN/rclone"
  chmod 755 "$BIN/rclone"
  rm -rf "$tmp"
fi
print "OK: $("$BIN/rclone" version | head -1)"

step "4/7 Scripts and start-at-login entries"
mkdir -p "$BIN" "$AGENTS" "$HOME/Library/Logs/RippleDrive" "$HOME/.config/ripple-drive/uploads"
for f in bin/*; do install -m 755 "$f" "$BIN/"; done
for f in launchd/*.plist; do sed "s#__HOME__#$HOME#g" "$f" > "$AGENTS/${f:t}"; done
print "OK: ripple-drive-signin, -mount, -upload, -find in $BIN"

step "5/7 Building the menu-bar app (about a minute)"
zsh app/build.sh "$APP" >/dev/null
LOGIN="$AGENTS/com.ripplemedia.ripple-drive-app.plist"
if [[ ! -e "$LOGIN" ]]; then   # same entry as the app's Settings > Start at Login
  /usr/libexec/PlistBuddy -c "Add :Label string com.ripplemedia.ripple-drive-app" \
    -c "Add :ProgramArguments array" -c "Add :ProgramArguments:0 string /usr/bin/open" \
    -c "Add :ProgramArguments:1 string -a" -c "Add :ProgramArguments:2 string $APP" \
    -c "Add :RunAtLoad bool true" "$LOGIN" >/dev/null
fi
print "OK: $APP"

step "6/7 Google sign-in"
if "$BIN/rclone" listremotes 2>/dev/null | grep -qx "rd-my:"; then
  print "OK: already signed in (run ripple-drive-signin --new to use another client or account)"
elif [[ $SIGNIN == 1 ]]; then
  "$BIN/ripple-drive-signin"
else
  print "Skipped: run ~/.local/bin/ripple-drive-signin when you're ready"
fi

step "7/7 Starting Ripple Drive"
if [[ $START == 0 ]]; then
  print "Skipped (--no-start)"
elif ! "$BIN/rclone" listremotes 2>/dev/null | grep -qx "rd-my:"; then
  print "Skipped: sign in first (ripple-drive-signin), then run zsh install.sh again"
else
  for label in com.ripplemedia.ripple-drive com.ripplemedia.ripple-drive-uploads; do
    if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
      launchctl kickstart -k "$DOMAIN/$label" >/dev/null
    else
      launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
    fi
  done
  if pgrep -xq RippleDrive; then osascript -e 'tell application id "com.ripplemedia.RippleDrive" to quit' >/dev/null 2>&1 || true; sleep 2; fi
  open "$APP"
  print -n "Waiting for the drive"
  for i in {1..45}; do mount | grep -q " on $MNT " && break; print -n "."; sleep 2; done
  print
  if mount | grep -q " on $MNT "; then
    print "OK: Ripple Drive is mounted at $MNT"
  else
    print "\033[33mThe drive isn't up yet. Turn on fuse-t in System Settings > General > Login Items & Extensions >"
    print "Extensions > By Category > File System Extensions, then choose Reconnect Drive in the Ripple Drive menu.\033[0m"
  fi
fi

if mount | grep -q " on $MNT "; then
  print "\n\033[1mDone.\033[0m Ripple Drive is in the Finder sidebar and the menu bar."
  print "  Search: Control-Option-F    Upload: right-click a file > Services > Upload to Ripple Drive"
else
  print "\n\033[1mInstalled.\033[0m Finish any skipped step above, then run zsh install.sh again to start the drive."
fi
[[ ":$PATH:" == *":$BIN:"* ]] || print "  To use the commands in Terminal, add this line to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""

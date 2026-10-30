#!/bin/zsh
# Removes Ripple Drive from this Mac. Your files in Google Drive are never touched.
#   zsh uninstall.sh         remove the app, scripts, start-at-login entries, cache and logs
#   zsh uninstall.sh --all   also remove the Google sign-in (rclone remotes rd-my and ripple-drive),
#                            unfinished-upload records and the app's settings
# rclone and fuse-t stay installed (other tools may use them): delete ~/.local/bin/rclone and run
# brew uninstall fuse-t yourself if nothing else needs them.
set -e
ALL=0
case $1 in
  --all) ALL=1 ;;
  "") ;;
  -h|--help) sed -n '2,7p' "$0" | cut -c3-; exit 0 ;;
  *) print "Unknown option: $1 (try --help)"; exit 1 ;;
esac

BIN="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
MNT="$HOME/RippleDrive"
STATE="$HOME/.config/ripple-drive/uploads"
DOMAIN="gui/$(id -u)"

pending=( "$STATE"/*.json(N) )
if (( ${#pending} )); then
  read "ans?${#pending} upload(s) haven't finished and will stop. Continue? [y/N] "
  [[ $ans == [yY]* ]] || exit 1
fi

print "Stopping Ripple Drive..."
if pgrep -xq RippleDrive; then osascript -e 'tell application id "com.ripplemedia.RippleDrive" to quit' >/dev/null 2>&1 || true; fi
for label in com.ripplemedia.ripple-drive com.ripplemedia.ripple-drive-uploads com.ripplemedia.ripple-drive-app; do
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
done
if mount | grep -q " on $MNT "; then
  umount "$MNT" 2>/dev/null || diskutil unmount force "$MNT" >/dev/null 2>&1 || true
fi
sleep 1
if mount | grep -q " on $MNT "; then
  print "The drive is still mounted at $MNT. Eject it in Finder, then run this again."; exit 1
fi

print "Removing files..."
rm -rf "$HOME/Applications/Ripple Drive.app"
rm -f "$BIN"/ripple-drive-{signin,mount,upload,find}
rm -f "$AGENTS"/com.ripplemedia.ripple-drive{,-uploads,-app}.plist
rm -rf "$HOME/Library/Caches/RippleDrive" "$HOME/Library/Logs/RippleDrive"
rmdir "$MNT" 2>/dev/null || true   # only if empty: never delete inside the mount point

if [[ $ALL == 1 ]]; then
  if [[ -x "$BIN/rclone" ]]; then
    for r in ripple-drive rd-my; do "$BIN/rclone" config delete "$r" >/dev/null 2>&1 || true; done
  fi
  rm -rf "$HOME/.config/ripple-drive"
  defaults delete com.ripplemedia.RippleDrive >/dev/null 2>&1 || true
  print "Signed out. To revoke access completely, remove Ripple Drive at https://myaccount.google.com/permissions"
fi

print "Ripple Drive is removed. Your Google Drive files are untouched."

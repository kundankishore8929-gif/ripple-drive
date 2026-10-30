# How Ripple Drive works

## The pieces

| Piece | Installed at | Job |
|---|---|---|
| `bin/ripple-drive-signin` | `~/.local/bin/` | First run: stores your client ID and secret and makes two rclone remotes. `rd-my` is the Google login; `ripple-drive` combines **My Drive** and **Shared with me** (`rd-my,shared_with_me:`) under one login. Later runs just sign in again. |
| `bin/ripple-drive-mount` | `~/.local/bin/` | Mounts `ripple-drive:` at `~/RippleDrive` through fuse-t's FSKit backend, retries the first mount, sets the disk size, and runs a watchdog. |
| `launchd/com.ripplemedia.ripple-drive.plist` | `~/Library/LaunchAgents/` | Starts the mount at login and restarts it if it exits with an error. |
| `bin/ripple-drive-upload` | `~/.local/bin/` | Resumable uploader (Python 3 standard library only). |
| `launchd/com.ripplemedia.ripple-drive-uploads.plist` | `~/Library/LaunchAgents/` | Runs `ripple-drive-upload --resume` at login and every 10 minutes. |
| `bin/ripple-drive-find` | `~/.local/bin/` | Search and share links through the Drive API. |
| `app/` | `~/Applications/Ripple Drive.app` | The menu-bar app (Swift/AppKit), built on your Mac by `app/build.sh`. |
| rclone | `~/.local/bin/rclone` | Official release, checksum-verified by the installer. |
| fuse-t | `/usr/local/lib/libfuse-t.dylib` | Makes macOS see the drive as a disk (FSKit, no kernel extension). |

## Reading: only the bytes you use

rclone mounts with `--vfs-cache-mode full`, which keeps a **sparse** cache: only the byte ranges an app actually reads are stored.

| Setting | Value | Why |
|---|---|---|
| `--vfs-cache-max-size` | 2G | The cache never grows past 2 GB |
| `--vfs-cache-max-age` | 15m | Cached pieces go 15 minutes after last use |
| `--vfs-cache-min-free-space` | 3G | The cache shrinks so your disk always has 3 GB free |
| `--vfs-read-chunk-size` | 8M | Google is asked for 8 MB at a time, so jumping around a video stays quick |
| `--vfs-read-ahead` | 32M | A little ahead of the playhead for smooth playback |
| `--dir-cache-time` / `--poll-interval` | 1000h / 30s | Folder listings stay cached; Drive's change feed keeps them fresh |

Stream mode (`--vfs-cache-mode off`) can't be used: fuse-t's FSKit backend opens every file read-write, which rclone refuses without a cache.

**Measured on a home connection:**
- About 90 Mbit/s reads.
- A video's first frame appears in 1–5 seconds.
- A jump to a new point takes 3–5 seconds, because Google answers each new range in about 1.2 s.

## Writing: uploads that resume

Writing into `~/RippleDrive` from Finder works, but rclone stages the file in the cache first. For big files the uploader is better, and it's what the app's drop tile and right-click actions use.

1. It resolves the destination folder (`My Drive/...` or `Shared with me/...`) and creates missing folders.
2. It skips the file if a file with the same name and MD5 is already there.
3. It opens a Google **resumable upload session** and sends the file from where it is, in 32 MB pieces.
4. It records the session and confirmed offset in `~/.config/ripple-drive/uploads/<id>.json`. After a crash, sleep or restart, it asks Google how many bytes arrived (`Content-Range: bytes */size`) and continues from there. Google keeps a session for a week; an expired one starts again.
5. It compares the result with Drive's MD5. With `--move`, the original goes to the Trash only after a match.

The app pauses and cancels uploads by dropping marker files (`<id>.pause`, `<id>.cancel`, `.pause-all`) in that folder. A lock file stops two uploaders running at once.

## Search and links

`ripple-drive-find search WORDS` asks Google for files whose names contain every word, across My Drive and shared drives, and turns each result into its path inside `~/RippleDrive`. Folder names are cached in `~/.config/ripple-drive/folders.json`.

`ripple-drive-find link` turns on "anyone with the link can view". If the file isn't yours to share, it returns the existing link instead.

## The menu-bar app

- **Status and storage:** checks the mount every 2 seconds, and checks Google's storage report every 15 minutes.
- **Icon:** the Ripple mark. It pulses while uploading, turns orange on an upload problem and red when Google needs you to sign in again, and fades when offline or unmounted.
- **Drop tile:** macOS 26+ doesn't deliver file drops to menu-bar icons. So when you drag a file from Finder toward the icon, a small drop tile appears under it. Every drop asks which folder to upload to, starting at My Drive and listing your recent folders.
- **Search:** **⌃⌥F** opens the search panel from any app (a Carbon hot key).
- **Right-click actions:** Finder's Upload / Move / Copy Link items are macOS Services declared in `Info.plist`.
- **Start at login:** a LaunchAgent, `com.ripplemedia.ripple-drive-app.plist`, which you can turn off in Settings.

## Disk space shown in Finder

My Drive and Shared with me are two views of one account, so the combined remote would count your free space twice. The mount script turns that report off (`--disable About`). Instead it sets the disk size to your account's real free space (`--vfs-disk-space-total-size`).

Google counts a terabyte as 1024⁴ bytes and Finder as 1000⁴, so the figure is scaled to match what drive.google.com shows.

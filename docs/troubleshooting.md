# Troubleshooting

## Mac

Logs are in `~/Library/Logs/RippleDrive/`. Open them from the menu-bar icon › **Show Logs**.

| Log | What's in it |
|---|---|
| `ripple-drive.log` | The mount |
| `uploads.log` | Uploads |
| `app.log` | The menu-bar app |
| `launchd.log` | Start-up errors |

For more detail, run the mount by hand: `RD_LOG_LEVEL=INFO ripple-drive-mount`.

| Problem | Fix |
|---|---|
| Icon is **red** | Google ended the sign-in (every 7 days while your app is in Testing). Click the icon › **Sign In Again**. To stop it for good, see [google-setup.md](google-setup.md#stop-the-weekly-sign-in). |
| Icon is **faded**, drive missing | You're offline, or the mount stopped. Click **Reconnect Drive**. If it never mounts, check that fuse-t is on in System Settings › General › Login Items & Extensions › Extensions › **By Category** › File System Extensions (in "By App" view the switch can look greyed out). |
| Icon is **orange** | An upload failed. Open the menu to see which one and why, then choose **Retry Failed Uploads**. |
| A file or folder you just made elsewhere says "No such file" | fuse-t remembers "not found" answers. Choose **Reconnect Drive** (about 10 seconds). Things you didn't look up first appear by themselves within about 20 seconds. |
| `mount stopped before calling Init` in the log | fuse-t needs a moment after an unmount. The mount script retries 4 times, then launchd tries again 30 seconds later. Nothing to do. |
| Finder shows a different free space from drive.google.com | The figure is set when the drive mounts. **Reconnect Drive** refreshes it. |
| A big Finder copy into the drive is slow or fills the disk | Use right-click › **Upload to Ripple Drive** instead. It reads straight from the original without staging it in the cache. |
| `rclone isn't installed` | Run `zsh install.sh` again. |
| "Google hasn't verified this app" | Expected: it's your own app. Click Advanced › Go to Ripple Drive. |
| "Access blocked: Ripple Drive has not completed the Google verification process" | Your Google account isn't a test user. Add it under Google Auth Platform › Audience › Test users. |
| Uploads stop at the same point every day | Google allows 750 GB of uploads per account per day. They carry on the next day. |

### Start over (Mac)

```bash
ripple-drive-signin --new          # new client ID / account
zsh uninstall.sh && zsh install.sh # fresh install (keeps your sign-in)
```

## Windows (beta)

Logs are in `%LOCALAPPDATA%\RippleDrive\logs\`. Open them from the taskbar icon › **Show Logs**.

| Log | What's in it |
|---|---|
| `ripple-drive.log` | The drive (rclone) |
| `mount.log` | Starting the drive, the drive letter, restarts |
| `uploads.log` | Uploads |
| `app.log` | The tray app |

For more detail, run the drive by hand in PowerShell (it keeps running until you press Ctrl+C):
`powershell -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\RippleDrive\bin\ripple-drive-mount.ps1 -LogLevel INFO`

| Problem | Fix |
|---|---|
| "Running scripts is disabled on this system" | Run the installer with the full line: `powershell -ExecutionPolicy Bypass -File windows\install.ps1`. It lets this one script run without changing any Windows setting. |
| No **R:** drive in File Explorer | Taskbar icon › **Reconnect Drive**, then wait 10 seconds. If the menu says "Not signed in", choose **Sign In**. Then look at `mount.log`. |
| `mount.log` says the drive letter is used by something else | Run the installer again with another letter, for example `... install.ps1 -Drive S:`. |
| `mount.log` says WinFsp isn't installed | Get it from [winfsp.dev/rel](https://winfsp.dev/rel/), then run the installer again. |
| Icon is **red** | Google ended the sign-in. Taskbar icon › **Sign In Again**. |
| Icon is **faded** | You're offline, or the drive stopped. Choose **Reconnect Drive**. |
| I can't see the icon | It's in the hidden icons: click **^** by the clock and drag the Ripple icon onto the taskbar. |
| No "Ripple Drive" in the right-click menu | On Windows 11 it's under **Show more options** (or Shift + right-click). |
| **Ctrl+Alt+F** does nothing | Another app already uses that shortcut. Use the taskbar icon › **Search Drive…** instead. |
| "Python 3 is needed" | Install it from [python.org](https://www.python.org/downloads/) with "Add python.exe to PATH" ticked, then run the installer again. |
| A big copy into R: is slow or fills the disk | Use right-click › **Ripple Drive › Upload to Ripple Drive** instead. It reads straight from the original. |

### Start over (Windows, in PowerShell)

```powershell
ripple-drive-signin --new                                                  # new client ID / account
powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1           # then run install.ps1 again
```

# Troubleshooting

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

## Start over

```bash
ripple-drive-signin --new          # new client ID / account
zsh uninstall.sh && zsh install.sh # fresh install (keeps your sign-in)
```

# Mounts Ripple Drive (rclone remote "ripple-drive:") as a drive letter through WinFsp.
# Sparse cache (--vfs-cache-mode full): only the parts of a file an app reads are kept, capped at 2 GB, cleared
# 15 min after last use, and the disk always keeps 3 GB free. Same settings as the Mac (bin/ripple-drive-mount).
# The tray app starts this hidden at login and starts it again if it stops; it can be run by hand too and keeps
# running until the drive stops.
#   ripple-drive-mount.ps1 [-Drive R:] [-Remote ripple-drive:] [-LogLevel NOTICE]
# Logs: %LOCALAPPDATA%\RippleDrive\logs\ripple-drive.log (rclone) and mount.log (this script).
param(
  [string]$Drive = "",
  [string]$Remote = "ripple-drive:",
  [string]$LogLevel = "NOTICE"
)
$ErrorActionPreference = "Continue"
$Base = Join-Path $env:LOCALAPPDATA "RippleDrive"
$Rclone = Join-Path $Base "bin\rclone.exe"
$Logs = Join-Path $Base "logs"
$Cache = Join-Path $Base "cache"
New-Item -ItemType Directory -Force -Path $Logs, $Cache | Out-Null

function Note($msg) {
  Add-Content -LiteralPath (Join-Path $Logs "mount.log") -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg)
}
# One Windows command-line argument, quoted the way rclone (Go) reads it back.
function Quote-Arg([string]$a) {
  if ($a -ne "" -and $a -notmatch '[\s"]') { return $a }
  return '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

if (-not $Drive) {
  $Drive = "R:"
  try { $d = (Get-Content -LiteralPath (Join-Path $Base "settings.json") -Raw | ConvertFrom-Json).drive; if ($d) { $Drive = $d } } catch {}
}
$Drive = $Drive.TrimEnd("\")
function Is-Mounted { Test-Path -LiteralPath "$Drive\" }

if (-not (Test-Path -LiteralPath $Rclone)) { Note "rclone not found at $Rclone (run install.ps1)"; exit 1 }
$winfsp = $false
foreach ($k in "HKLM:\SOFTWARE\WOW6432Node\WinFsp", "HKLM:\SOFTWARE\WinFsp") {
  $dir = (Get-ItemProperty -Path $k -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
  if ($dir -and (Test-Path -LiteralPath (Join-Path $dir "bin"))) { $winfsp = $true }
}
if (-not $winfsp) { Note "WinFsp isn't installed (run install.ps1 again, or get it from https://winfsp.dev)"; exit 1 }

# A mount left over from a crash or an earlier start holds the drive letter: stop that rclone first.
if (Is-Mounted) {
  Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "* mount *" -and $_.CommandLine -like "* $Drive *" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10 -and (Is-Mounted); $i++) { Start-Sleep 1 }
  if (Is-Mounted) { Note "drive letter $Drive is used by something else; pick another one with install.ps1 -Drive"; exit 1 }
}

# Space shown in File Explorer: the combined drive would count the account twice (My Drive and Shared with me are
# two views of one account), so its own report is off and the disk size is set to the account's real free space
# at each mount (last known value if Google can't be reached). Explorer counts 1 TB as 1024^4 bytes like Google,
# so the figure needs no scaling (the Mac's Finder counts 1000^4 and does).
$spaceFile = Join-Path $Base "free-bytes"
$free = $null
$about = & $Rclone about rd-my: --json 2>$null | Out-String
if ($LASTEXITCODE -eq 0) { try { $free = [int64]($about | ConvertFrom-Json).free } catch {} }
if ($free) { Set-Content -LiteralPath $spaceFile -Value $free } elseif (Test-Path -LiteralPath $spaceFile) {
  try { $free = [int64](Get-Content -LiteralPath $spaceFile -Raw).Trim() } catch {}
}
$space = @()
if ($free) { $space = @("--disable", "About", "--vfs-disk-space-total-size", "${free}B") }

$rcloneArgs = @("mount", $Remote, $Drive) + $space + @(
  "--volname", "Ripple Drive",
  "--cache-dir", $Cache,
  "--vfs-cache-mode", "full",
  "--vfs-cache-max-size", "2G",
  "--vfs-cache-max-age", "15m",
  "--vfs-cache-min-free-space", "3G",
  "--vfs-cache-poll-interval", "30s",
  "--buffer-size", "16M",
  "--vfs-read-chunk-size", "8M",
  "--vfs-read-ahead", "32M",
  "--drive-chunk-size", "64M",
  "--dir-cache-time", "1000h",
  "--poll-interval", "30s",
  "--exclude", "._*",
  "--exclude", ".DS_Store",
  "--log-file", (Join-Path $Logs "ripple-drive.log"),
  "--log-level", $LogLevel)
$argLine = ($rcloneArgs | ForEach-Object { Quote-Arg $_ }) -join " "

$p = $null
foreach ($attempt in 1..3) {
  $p = Start-Process -FilePath $Rclone -ArgumentList $argLine -WindowStyle Hidden -PassThru
  $null = $p.Handle                            # keeps the exit code readable after rclone ends
  for ($i = 0; $i -lt 60; $i++) { if ((Is-Mounted) -or $p.HasExited) { break }; Start-Sleep 1 }
  if (Is-Mounted) { break }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Note "mount attempt $attempt failed (see ripple-drive.log)"
  Start-Sleep 5
}
if (-not (Is-Mounted)) { exit 1 }
Note "mounted $Remote at $Drive"

# Watchdog: if the drive is gone for two checks in a row while rclone still runs, stop rclone and exit 1 so the
# tray app starts this script again.
$misses = 0
while (-not $p.HasExited) {
  Start-Sleep 20
  if (Is-Mounted) { $misses = 0 } else { $misses++ }
  if ($misses -ge 2) {
    Note "drive vanished; restarting rclone"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    exit 1
  }
}
Note "rclone stopped (exit $($p.ExitCode))"
exit 1

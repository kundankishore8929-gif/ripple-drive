# Removes Ripple Drive from this PC. Your files in Google Drive are never touched.
#   powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1         remove the app, drive and commands
#     -All     also remove the Google sign-in (the rd-my and ripple-drive rclone remotes)
#     -Yes     don't ask, even when uploads are unfinished
# WinFsp and Python stay (other apps may use them); remove them in Settings > Apps if you want.
param([switch]$All, [switch]$Yes)
$ErrorActionPreference = "Continue"
$Base = Join-Path $env:LOCALAPPDATA "RippleDrive"
$Bin = Join-Path $Base "bin"
$Rclone = Join-Path $Bin "rclone.exe"

$pending = @(Get-ChildItem -LiteralPath (Join-Path $Base "uploads") -Filter "*.json" -ErrorAction SilentlyContinue)
if ($pending.Count -gt 0 -and -not $Yes) {
  Write-Host "$($pending.Count) upload(s) haven't finished. Removing Ripple Drive stops them (the originals stay where they are)."
  $ans = Read-Host "Remove anyway? (y/N)"
  if ($ans -notmatch "^[yY]") { Write-Host "Nothing removed."; exit 1 }
}

# Stop the tray app, the drive and any running upload.
Get-Process RippleDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -eq $Rclone -or ($_.CommandLine -and $_.CommandLine -like "*RippleDrive\bin\ripple-drive-*") } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 2

if ($All -and (Test-Path -LiteralPath $Rclone)) {
  foreach ($r in "ripple-drive", "rd-shared", "rd-my") { & $Rclone config delete $r 2>$null | Out-Null }
  Write-Host "Removed the Google sign-in."
}

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Ripple Drive" -ErrorAction SilentlyContinue
$hkcu = [Microsoft.Win32.Registry]::CurrentUser
foreach ($kind in "*", "Directory") { $hkcu.DeleteSubKeyTree("Software\Classes\$kind\shell\RippleDrive", $false) }
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath("Programs")) "Ripple Drive.lnk") -Force -ErrorAction SilentlyContinue
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath) {
  $kept = ($userPath -split ";" | Where-Object { $_ -and $_ -ne $Bin }) -join ";"
  if ($kept -ne $userPath) { [Environment]::SetEnvironmentVariable("Path", $kept, "User") }
}
Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $Base) { Write-Host "Some files in $Base are still in use; delete that folder after a restart." }

Write-Host "`nRipple Drive is removed. Your files in Google Drive are untouched."
if (-not $All) { Write-Host "The Google sign-in is kept in rclone's config; run uninstall.ps1 -All to remove it too." }
Write-Host "WinFsp and Python stay installed (other apps may use them): remove them in Settings > Apps if you like."

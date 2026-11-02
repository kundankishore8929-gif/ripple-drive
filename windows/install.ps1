# Ripple Drive installer for Windows (beta): your Google Drive as a drive letter on your PC.
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1     install (or update), sign in, start the drive
#     -NoSignin       skip the Google sign-in (run ripple-drive-signin later)
#     -NoStart        install only: don't start the drive or the tray app
#     -UpdateRclone   also replace rclone with the latest release
#     -Drive S:       use another drive letter (default: R:, or the first free one after it)
# Everything goes into %LOCALAPPDATA%\RippleDrive and needs no admin rights. Only WinFsp (it lets Windows show
# the drive) asks you to approve it once, and Python is installed for you if this PC doesn't have it yet.
param([switch]$NoSignin, [switch]$NoStart, [switch]$UpdateRclone, [string]$Drive = "")
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"         # Windows PowerShell downloads crawl with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = Split-Path -Parent $PSScriptRoot
$Base = Join-Path $env:LOCALAPPDATA "RippleDrive"
$Bin = Join-Path $Base "bin"
$Rclone = Join-Path $Bin "rclone.exe"
$Exe = Join-Path $Bin "RippleDrive.exe"
$SettingsPath = Join-Path $Base "settings.json"
function Step($t) { Write-Host "`n$t" -ForegroundColor White }
function OK($t) { Write-Host "OK: $t" -ForegroundColor Green }
function Fail($t) { Write-Host "`n$t" -ForegroundColor Red; exit 1 }
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

Step "1/7 Checking this PC"
$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
switch ($arch) {
  "AMD64" { $rcArch = "amd64" }
  "ARM64" { $rcArch = "arm64" }
  default { Fail "Ripple Drive needs 64-bit Windows (this PC: $arch)." }
}
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 17763) { Fail "Ripple Drive needs Windows 10 (version 1809 or later) or Windows 11." }
OK "Windows build $build, $arch"

Step "2/7 WinFsp (lets Windows show the drive)"
function Find-WinFsp {
  foreach ($k in "HKLM:\SOFTWARE\WOW6432Node\WinFsp", "HKLM:\SOFTWARE\WinFsp") {
    $d = (Get-ItemProperty -Path $k -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
    if ($d -and (Test-Path -LiteralPath (Join-Path $d "bin"))) { return $d }
  }
  return $null
}
if (-not (Find-WinFsp)) {
  Write-Host "Installing WinFsp. Windows asks you to allow it: click Yes."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id WinFsp.WinFsp --accept-package-agreements --accept-source-agreements --silent | Out-Host
  }
  if (-not (Find-WinFsp)) {
    # No winget (or it failed): the installer from WinFsp's own GitHub releases, checked for its maker's signature.
    try {
      $rel = Invoke-RestMethod "https://api.github.com/repos/winfsp/winfsp/releases/latest" -Headers @{ "User-Agent" = "ripple-drive" }
      $asset = $rel.assets | Where-Object { $_.name -like "winfsp-*.msi" } | Select-Object -First 1
      $msi = Join-Path $env:TEMP $asset.name
      Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing
      $sig = Get-AuthenticodeSignature -LiteralPath $msi
      if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notmatch "Navimatics|Zissimopoulos") {
        Remove-Item -LiteralPath $msi -Force
        Fail "The WinFsp download isn't signed by its maker, so it wasn't installed. Get it from https://winfsp.dev/rel/"
      }
      Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qb" -Verb RunAs -Wait
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    } catch { Write-Host $_ }
  }
  if (-not (Find-WinFsp)) { Fail "WinFsp didn't install. Get it from https://winfsp.dev/rel/, then run install.ps1 again." }
}
OK "WinFsp in $(Find-WinFsp)"

Step "3/7 Python (runs the uploader and search)"
function Find-Python {
  $cands = New-Object System.Collections.Generic.List[string]
  if (Get-Command py -ErrorAction SilentlyContinue) {
    $p = & py -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -Last 1
    if ($p) { $cands.Add(([string]$p).Trim()) }
  }
  Get-Command python.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike "*\WindowsApps\*" } |
    ForEach-Object { $cands.Add($_.Source) }
  Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | ForEach-Object { $cands.Add($_.FullName) }
  foreach ($x in $cands) {
    if (-not (Test-Path -LiteralPath $x)) { continue }
    $v = & $x -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
    if ($v -and ([version]([string]$v).Trim()) -ge [version]"3.9" -and (Test-Path -LiteralPath (Join-Path (Split-Path $x) "pythonw.exe"))) { return $x }
  }
  return $null
}
$Py = Find-Python
if (-not $Py) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "Installing Python 3 for your account..."
    winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements --silent | Out-Host
    $Py = Find-Python
  }
  if (-not $Py) { Fail "Python 3 is needed. Install it from https://www.python.org/downloads/ (tick `"Add python.exe to PATH`"), then run install.ps1 again." }
}
OK "$(& $Py --version 2>&1) at $Py"

Step "4/7 rclone (talks to Google Drive)"
# Stop a running copy first: Windows won't replace files that are in use.
Get-Process RippleDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -eq $Rclone } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $Bin, (Join-Path $Base "logs"), (Join-Path $Base "uploads") | Out-Null
if (-not (Test-Path -LiteralPath $Rclone) -or $UpdateRclone) {
  $rv = ([string](Invoke-RestMethod "https://downloads.rclone.org/version.txt")).Trim().Split(" ")[-1]
  if ($rv -notlike "v*") { Fail "Couldn't read rclone's latest version from downloads.rclone.org." }
  $zip = "rclone-$rv-windows-$rcArch.zip"
  $tmp = Join-Path $env:TEMP ("ripple-drive-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  Write-Host "Downloading rclone $rv..."
  Invoke-WebRequest "https://downloads.rclone.org/$rv/$zip" -OutFile (Join-Path $tmp $zip) -UseBasicParsing
  $sums = [string](Invoke-RestMethod "https://downloads.rclone.org/$rv/SHA256SUMS")
  $want = $sums -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "\s$([regex]::Escape($zip))$" } |
    ForEach-Object { ($_ -split "\s+")[0] } | Select-Object -First 1
  $got = (Get-FileHash -LiteralPath (Join-Path $tmp $zip) -Algorithm SHA256).Hash
  if (-not $want -or $want.ToLower() -ne $got.ToLower()) {
    Remove-Item -LiteralPath $tmp -Recurse -Force
    Fail "The rclone download didn't match its checksum, so nothing was installed."
  }
  Expand-Archive -LiteralPath (Join-Path $tmp $zip) -DestinationPath $tmp
  Copy-Item -LiteralPath (Join-Path (Join-Path $tmp ($zip -replace "\.zip$", "")) "rclone.exe") -Destination $Rclone -Force
  Remove-Item -LiteralPath $tmp -Recurse -Force
}
OK (& $Rclone version | Select-Object -First 1)

Step "5/7 Scripts, tray app and right-click menu"
$old = $null
if (Test-Path -LiteralPath $SettingsPath) { try { $old = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json } catch {} }
if (-not $Drive -and $old -and $old.drive) { $Drive = $old.drive }
if (-not $Drive) {
  $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
  $free = "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "Q", "P" | Where-Object { $used -notcontains $_ } | Select-Object -First 1
  if (-not $free) { Fail "No free drive letter between P: and Z:. Run install.ps1 -Drive <letter>: with a free one." }
  $Drive = "${free}:"
}
$Drive = $Drive.TrimEnd("\").ToUpper()
if ($Drive -notmatch "^[A-Z]:$") { Fail "-Drive needs a letter and a colon, like S:" }
$Pyw = Join-Path (Split-Path $Py) "pythonw.exe"
Write-Utf8 $SettingsPath (@{ drive = $Drive; python = $Py; pythonw = $Pyw } | ConvertTo-Json)

Copy-Item -LiteralPath (Join-Path $Repo "bin\ripple-drive-upload"), (Join-Path $Repo "bin\ripple-drive-find") -Destination $Bin -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "ripple-drive-mount.ps1"), (Join-Path $PSScriptRoot "ripple-drive-signin.ps1") -Destination $Bin -Force
Get-ChildItem -LiteralPath $Bin | Unblock-File
# Commands for a terminal: ripple-drive-upload, ripple-drive-find, ripple-drive-signin.
$enc = [Text.Encoding]::Default
[IO.File]::WriteAllText((Join-Path $Bin "ripple-drive-upload.cmd"), "@`"$Py`" `"%~dp0ripple-drive-upload`" %*`r`n", $enc)
[IO.File]::WriteAllText((Join-Path $Bin "ripple-drive-find.cmd"), "@`"$Py`" `"%~dp0ripple-drive-find`" %*`r`n", $enc)
[IO.File]::WriteAllText((Join-Path $Bin "ripple-drive-signin.cmd"),
  "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0ripple-drive-signin.ps1`" %*`r`n", $enc)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ";") -notcontains $Bin) {
  [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(";"), $Bin) -join ";").TrimStart(";"), "User")
}

Write-Host "Building the tray app..."
& (Join-Path $PSScriptRoot "build.ps1") -Out $Exe
if (-not (Test-Path -LiteralPath $Exe)) { Fail "The tray app didn't build (see the messages above)." }

# Start at login, the Start menu, and a "Ripple Drive" submenu on files and folders in File Explorer
# (Windows 11: under "Show more options").
$prefs = $null
$prefsPath = Join-Path $Base "app.json"
if (Test-Path -LiteralPath $prefsPath) { try { $prefs = Get-Content -LiteralPath $prefsPath -Raw | ConvertFrom-Json } catch {} }
if (-not $prefs -or $prefs.startAtLogin -ne $false) {     # unless you turned Start at Login off in the app
  $run = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Microsoft\Windows\CurrentVersion\Run")
  $run.SetValue("Ripple Drive", "`"$Exe`"")
  $run.Close()
}
$lnk = Join-Path ([Environment]::GetFolderPath("Programs")) "Ripple Drive.lnk"
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sc.TargetPath = $Exe; $sc.IconLocation = "$Exe,0"; $sc.Description = "Your Google Drive as a drive on this PC"; $sc.Save()
# .NET's registry calls, because PowerShell reads the "*" key (all files) as a wildcard.
$hkcu = [Microsoft.Win32.Registry]::CurrentUser
foreach ($kind in "*", "Directory") {
  $path = "Software\Classes\$kind\shell\RippleDrive"
  $hkcu.DeleteSubKeyTree($path, $false)
  $root = $hkcu.CreateSubKey($path)
  $root.SetValue("MUIVerb", "Ripple Drive")
  $root.SetValue("Icon", "`"$Exe`",0")
  $root.SetValue("SubCommands", "")
  $root.SetValue("MultiSelectModel", "Player")
  $verbs = @(@("1upload", "Upload to Ripple Drive", "--upload"), @("2move", "Move to Ripple Drive", "--move"))
  if ($kind -eq "*") { $verbs += , @("3link", "Copy Ripple Drive Link", "--link") }
  foreach ($v in $verbs) {
    $k = $root.CreateSubKey("shell\$($v[0])")
    $k.SetValue("MUIVerb", $v[1])
    $k.SetValue("MultiSelectModel", "Player")
    $c = $k.CreateSubKey("command")
    $c.SetValue("", "`"$Exe`" $($v[2]) `"%1`"")
    $c.Close(); $k.Close()
  }
  $root.Close()
}
OK "tray app, Start menu, right-click menu; commands in $Bin"

Step "6/7 Google sign-in"
$remotes = @(& $Rclone listremotes 2>$null)
if ($remotes -contains "rd-my:") {
  OK "already signed in (run ripple-drive-signin --new to use another client or account)"
} elseif (-not $NoSignin) {
  & (Join-Path $Bin "ripple-drive-signin.ps1")
} else {
  Write-Host "Skipped: run ripple-drive-signin when you're ready"
}

Step "7/7 Starting Ripple Drive"
$remotes = @(& $Rclone listremotes 2>$null)
if ($NoStart) {
  Write-Host "Skipped (-NoStart)"
} elseif ($remotes -notcontains "rd-my:") {
  Write-Host "Skipped: sign in first (ripple-drive-signin), then run install.ps1 again"
} else {
  Start-Process -FilePath $Exe
  Write-Host -NoNewline "Waiting for the drive"
  for ($i = 0; $i -lt 45 -and -not (Test-Path -LiteralPath "$Drive\"); $i++) { Write-Host -NoNewline "."; Start-Sleep 2 }
  Write-Host ""
  if (Test-Path -LiteralPath "$Drive\") { OK "Ripple Drive is at $Drive\" }
  else { Write-Host "The drive isn't up yet. Right-click the Ripple icon by the clock > Reconnect Drive, or see docs\troubleshooting.md." -ForegroundColor Yellow }
}

if (Test-Path -LiteralPath "$Drive\") {
  Write-Host "`nDone. Ripple Drive is $Drive in File Explorer, and its icon is by the clock." -ForegroundColor White
  Write-Host "  Search: Ctrl+Alt+F    Upload: right-click a file > Ripple Drive > Upload to Ripple Drive"
} else {
  Write-Host "`nInstalled. Finish any skipped step above, then run install.ps1 again to start the drive." -ForegroundColor White
}
Write-Host "  Commands (ripple-drive-upload, ripple-drive-find, ripple-drive-signin) work in new terminal windows."

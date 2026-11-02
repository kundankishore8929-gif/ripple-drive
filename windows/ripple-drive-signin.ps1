# Signs Ripple Drive in to Google Drive with your own OAuth client (docs/google-setup.md).
#   ripple-drive-signin          first time: asks for the client ID and secret, then opens Google's sign-in.
#                                after that: just signs in again.
#   ripple-drive-signin --new    start over with a new client ID and secret (or -New).
# Remotes: rd-my (the Google login) and ripple-drive (My Drive + Shared with me, combined; this is what gets
# mounted). Secrets stay in rclone's config on this PC (%APPDATA%\rclone\rclone.conf).
param(
  [switch]$New,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = "Continue"
if ($Rest -contains "--new") { $New = $true }
$Rclone = Join-Path $env:LOCALAPPDATA "RippleDrive\bin\rclone.exe"
if (-not (Test-Path -LiteralPath $Rclone)) { Write-Host "rclone isn't installed at $Rclone. Run install.ps1 first."; exit 1 }

$remotes = @(& $Rclone listremotes 2>$null)
if (-not $New -and ($remotes -contains "rd-my:")) {
  Write-Host "Ripple Drive: signing in again. Google's page opens in your browser:"
  Write-Host "pick your account, then Continue > Allow.`n"
  & $Rclone config reconnect rd-my: --auto-confirm | Out-Null
} else {
  Write-Host "Ripple Drive sign-in (you need your Google client ID and secret: see docs/google-setup.md)`n"
  $cid = ([string](Read-Host "Paste the Google client ID, then press Enter")).Trim()
  $secure = Read-Host "Paste the client secret (stays hidden), then press Enter" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  $csec = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim()
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  if (-not $cid -or -not $csec) { Write-Host "Both the client ID and the secret are needed."; exit 1 }

  foreach ($r in "rd-my", "rd-shared", "ripple-drive") { & $Rclone config delete $r 2>$null | Out-Null }

  Write-Host "`nA Google sign-in page opens in your browser."
  Write-Host "Pick your account. On `"Google hasn't verified this app`", click Advanced > Go to Ripple Drive"
  Write-Host "(it's your own app), then Continue > Allow.`n"
  & $Rclone config create rd-my drive "client_id=$cid" "client_secret=$csec" scope=drive | Out-Null
  # "Shared with me" reuses the same login through a connection string, so there is one token to renew. The
  # section is written straight into rclone.conf: Windows PowerShell can't hand the quoted upstreams to rclone intact.
  $conf = ([string](& $Rclone config file | Select-Object -Last 1)).Trim()
  Add-Content -LiteralPath $conf -Encoding ASCII -Value (
    "`r`n[ripple-drive]`r`ntype = combine`r`n" +
    'upstreams = "My Drive=rd-my:" "Shared with me=rd-my,shared_with_me:"' + "`r`n")
}

Write-Host "Checking the connection..."
& $Rclone lsd ripple-drive:
if ($LASTEXITCODE -eq 0) { Write-Host "`nSigned in." } else { Write-Host "`nThe sign-in didn't finish. Run ripple-drive-signin again."; exit 1 }

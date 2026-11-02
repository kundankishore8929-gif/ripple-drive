# Builds the tray app (RippleDrive.cs) into RippleDrive.exe with the C# compiler that ships with Windows
# (.NET Framework 4.x), so nothing is downloaded and no runtime is installed.
#   build.ps1 [-Out <path to RippleDrive.exe>]
param([string]$Out = (Join-Path $env:LOCALAPPDATA "RippleDrive\bin\RippleDrive.exe"))
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { Write-Host ".NET Framework 4 wasn't found (it is part of Windows 10 and 11), so the tray app can't be built."; exit 1 }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$Out" "/win32icon:$(Join-Path $PSScriptRoot 'RippleDrive.ico')" `
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll `
  (Join-Path $PSScriptRoot "RippleDrive.cs") | Where-Object { $_ -notmatch "only supports language versions up to C# 5|aka.ms/LangVersion|^\s*$" }
if (-not (Test-Path -LiteralPath $Out)) { exit 1 }
exit 0

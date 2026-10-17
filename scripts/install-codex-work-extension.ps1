[CmdletBinding()]
param(
  [ValidateSet('Install', 'Status')]
  [string]$Action = 'Install',
  [string]$Destination = 'D:\CodexData\codex-work-extension',
  [int]$Port = 43123,
  [switch]$OpenChromeExtensions
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\assets\codex-work-bridge-extension'
$source = (Resolve-Path -LiteralPath $source).ProviderPath

if ($Action -eq 'Status') {
  $manifest = Join-Path $Destination 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    Write-Host "Codex Work extension is not staged at $Destination"
    exit 1
  }
  $data = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
  [pscustomobject]@{ name = $data.name; version = $data.version; path = $Destination; endpoint = "ws://127.0.0.1:$Port" } | ConvertTo-Json -Compress
  exit 0
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Get-ChildItem -LiteralPath $source -File -Recurse | ForEach-Object {
  $relative = $_.FullName.Substring($source.Length).TrimStart('\')
  $target = Join-Path $Destination $relative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
  Copy-Item -LiteralPath $_.FullName -Destination $target -Force
}

$serverScript = Join-Path $PSScriptRoot 'start-codex-work-app-server.ps1'
& $serverScript -Action Start -Port $Port

if ($OpenChromeExtensions) {
  $chromeCandidates = @(
    (Join-Path ${env:ProgramFiles} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:LOCALAPPDATA} 'Google\Chrome\Application\chrome.exe')
  )
  $chrome = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($chrome) {
    Start-Process -FilePath $chrome -ArgumentList 'chrome://extensions' | Out-Null
  } else {
    Write-Warning 'Chrome executable was not found; open chrome://extensions manually.'
  }
}

Write-Host ''
Write-Host 'Codex Desktop Work extension staged.' -ForegroundColor Green
Write-Host "Unpacked extension directory: $Destination"
Write-Host 'Open chrome://extensions, enable Developer mode, choose Load unpacked, and select that directory.'
Write-Host 'This is a separate local extension; the official ChatGPT extension is left untouched.'

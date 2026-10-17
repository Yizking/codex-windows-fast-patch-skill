[CmdletBinding()]
param(
  [ValidateSet('Start', 'Stop', 'Status')]
  [string]$Action = 'Start',
  [int]$Port = 43123,
  [string]$WorkRoot = 'D:\CodexData\codex-work-bridge',
  [string]$ExtensionRoot = 'D:\CodexData\codex-work-extension'
)

$ErrorActionPreference = 'Stop'

function Get-CodexCliPath {
  $candidates = @(
    (Join-Path $env:USERPROFILE '.codex\plugins\.plugin-appserver\codex.exe'),
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe')
  )
  $hostState = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'
  if (Test-Path -LiteralPath $hostState -PathType Leaf) {
    try {
      $state = Get-Content -Raw -LiteralPath $hostState | ConvertFrom-Json
      foreach ($entry in @($state.entries)) {
        if ($entry.paths.codexCliPath) { $candidates += [string]$entry.paths.codexCliPath }
      }
    } catch {
      Write-Verbose "Could not read native-host state: $($_.Exception.Message)"
    }
  }
  $command = Get-Command codex.exe -ErrorAction SilentlyContinue
  if ($command) { $candidates += $command.Source }
  foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
  }
  throw 'Could not locate a Codex CLI binary. Install/start Codex Desktop once, then retry.'
}

function Get-StatePaths {
  New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
  return [pscustomobject]@{
    Pid = Join-Path $WorkRoot 'bridge-server.pid'
    StdOut = Join-Path $WorkRoot 'bridge-server.stdout.log'
    StdErr = Join-Path $WorkRoot 'bridge-server.stderr.log'
  }
}

function Get-ExtensionId {
  $manifestPath = Join-Path $ExtensionRoot 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Extension manifest is missing: $manifestPath" }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace([string]$manifest.key)) { throw 'The local extension manifest must contain a stable public key.' }
  $publicKey = [Convert]::FromBase64String([string]$manifest.key)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $digest = $sha.ComputeHash($publicKey) } finally { $sha.Dispose() }
  $builder = [System.Text.StringBuilder]::new()
  for ($index = 0; $index -lt 16; $index++) {
    [void]$builder.Append([char](97 + ($digest[$index] -shr 4)))
    [void]$builder.Append([char](97 + ($digest[$index] -band 15)))
  }
  return $builder.ToString()
}

function Get-RecordedProcess {
  param([object]$Paths)
  if (-not (Test-Path -LiteralPath $Paths.Pid -PathType Leaf)) { return $null }
  $raw = (Get-Content -Raw -LiteralPath $Paths.Pid).Trim()
  $processId = 0
  if (-not [int]::TryParse($raw, [ref]$processId) -or $processId -le 0) { return $null }
  return Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue
}

function Test-AppServerHealth {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 2
    return $response.StatusCode -eq 200
  } catch { return $false }
}

function Test-RecordedBridgeProcess {
  param([object]$Process)
  if (-not $Process) { return $false }
  $commandLine = [string]$Process.CommandLine
  return $commandLine -match 'run-codex-work-bridge\.ps1' -and $commandLine -match "-Port\s+$Port"
}

$paths = Get-StatePaths
if ($Action -eq 'Status') {
  $process = Get-RecordedProcess $paths
  [pscustomobject]@{
    endpoint = "ws://127.0.0.1:$Port/ws"
    mode = 'origin-checked-stdio-bridge'
    healthy = (Test-AppServerHealth) -and (Test-RecordedBridgeProcess $process)
    pid = if (Test-RecordedBridgeProcess $process) { [int]$process.ProcessId } else { $null }
    executable = if ($process) { [string]$process.ExecutablePath } else { $null }
  } | ConvertTo-Json -Compress
  exit 0
}

if ($Action -eq 'Stop') {
  $process = Get-RecordedProcess $paths
  if (-not $process) {
    Remove-Item -LiteralPath $paths.Pid -Force -ErrorAction SilentlyContinue
    Write-Host 'Codex Work bridge is not running.'
    exit 0
  }
  if (-not (Test-RecordedBridgeProcess $process)) {
    throw "Refusing to stop an unverified process (PID $($process.ProcessId))."
  }
  try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/shutdown" -TimeoutSec 2 | Out-Null } catch {}
  $processId = [int]$process.ProcessId
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 150
    if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { break }
  }
  if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
    & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $processId /T /F | Out-Null
  }
  Remove-Item -LiteralPath $paths.Pid -Force -ErrorAction SilentlyContinue
  Write-Host 'Codex Work bridge and its child app-server stopped.'
  exit 0
}

if ((Test-AppServerHealth) -and (Test-RecordedBridgeProcess (Get-RecordedProcess $paths))) {
  Write-Host "Codex Work origin-checked bridge already healthy at ws://127.0.0.1:$Port/ws"
  exit 0
}
if (Test-AppServerHealth) {
  throw "Port $Port is already serving an unverified local service; it was left untouched. Choose another -Port."
}

$codex = Get-CodexCliPath
$extensionId = Get-ExtensionId
$bridgeScript = Join-Path $PSScriptRoot 'run-codex-work-bridge.ps1'
$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
}
$arguments = @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $bridgeScript + '"'),
  '-Port', [string]$Port,
  '-ExtensionId', $extensionId,
  '-CodexCliPath', ('"' + $codex + '"'),
  '-WorkRoot', ('"' + $WorkRoot + '"')
)
$process = Start-Process -FilePath $powershell -ArgumentList $arguments -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -RedirectStandardOutput $paths.StdOut -RedirectStandardError $paths.StdErr -PassThru
Set-Content -LiteralPath $paths.Pid -Value $process.Id -Encoding ascii

$deadline = (Get-Date).AddSeconds(20)
do {
  Start-Sleep -Milliseconds 350
  if ((Test-AppServerHealth) -and (Test-RecordedBridgeProcess (Get-RecordedProcess $paths))) {
    Write-Host "Codex Work origin-checked bridge ready: ws://127.0.0.1:$Port/ws" -ForegroundColor Green
    exit 0
  }
  $process.Refresh()
  if ($process.HasExited) {
    $tail = if (Test-Path -LiteralPath $paths.StdErr) { (Get-Content -LiteralPath $paths.StdErr -Tail 8) -join ' ' } else { '' }
    throw "Codex Work bridge exited before health check. $tail"
  }
} while ((Get-Date) -lt $deadline)

throw "Timed out waiting for Codex Work bridge health. See $($paths.StdErr)."

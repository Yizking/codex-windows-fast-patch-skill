[CmdletBinding()]
param(
  [ValidateSet('Start', 'Stop', 'Status')]
  [string]$Action = 'Start',
  [int]$Port = 43123,
  [string]$WorkRoot = 'D:\CodexData\codex-work-bridge'
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
    Pid = Join-Path $WorkRoot 'app-server.pid'
    StdOut = Join-Path $WorkRoot 'app-server.stdout.log'
    StdErr = Join-Path $WorkRoot 'app-server.stderr.log'
  }
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

$paths = Get-StatePaths
if ($Action -eq 'Status') {
  $process = Get-RecordedProcess $paths
  [pscustomobject]@{
    endpoint = "ws://127.0.0.1:$Port"
    healthy = Test-AppServerHealth
    pid = if ($process) { [int]$process.ProcessId } else { $null }
    executable = if ($process) { [string]$process.ExecutablePath } else { $null }
  } | ConvertTo-Json -Compress
  exit 0
}

if ($Action -eq 'Stop') {
  $process = Get-RecordedProcess $paths
  if (-not $process) {
    Remove-Item -LiteralPath $paths.Pid -Force -ErrorAction SilentlyContinue
    Write-Host 'Codex Work app-server is not running.'
    exit 0
  }
  $commandLine = [string]$process.CommandLine
  if ($commandLine -notmatch 'app-server' -or $commandLine -notmatch "43123|$Port") {
    throw "Refusing to stop an unverified process (PID $($process.ProcessId))."
  }
  Stop-Process -Id ([int]$process.ProcessId) -Force
  Remove-Item -LiteralPath $paths.Pid -Force -ErrorAction SilentlyContinue
  Write-Host 'Codex Work app-server stopped.'
  exit 0
}

if (Test-AppServerHealth) {
  Write-Host "Codex Work app-server already healthy at ws://127.0.0.1:$Port"
  exit 0
}

$codex = Get-CodexCliPath
$arguments = @('app-server', '--listen', "ws://127.0.0.1:$Port")
$process = Start-Process -FilePath $codex -ArgumentList $arguments -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -RedirectStandardOutput $paths.StdOut -RedirectStandardError $paths.StdErr -PassThru
Set-Content -LiteralPath $paths.Pid -Value $process.Id -Encoding ascii

$deadline = (Get-Date).AddSeconds(20)
do {
  Start-Sleep -Milliseconds 350
  if (Test-AppServerHealth) {
    Write-Host "Codex Work app-server ready: ws://127.0.0.1:$Port" -ForegroundColor Green
    exit 0
  }
  $process.Refresh()
  if ($process.HasExited) {
    $tail = if (Test-Path -LiteralPath $paths.StdErr) { (Get-Content -LiteralPath $paths.StdErr -Tail 8) -join ' ' } else { '' }
    throw "Codex app-server exited before health check. $tail"
  }
} while ((Get-Date) -lt $deadline)

throw "Timed out waiting for Codex app-server health. See $($paths.StdErr)."

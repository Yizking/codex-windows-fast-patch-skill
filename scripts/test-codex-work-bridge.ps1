[CmdletBinding()]
param(
  [string]$Endpoint = 'ws://127.0.0.1:43123',
  [string]$ExtensionRoot = 'D:\CodexData\codex-work-extension',
  [switch]$TurnSmoke
)

$ErrorActionPreference = 'Stop'
$manifest = Join-Path $ExtensionRoot 'manifest.json'
foreach ($required in @('manifest.json', 'sidepanel.html', 'sidepanel.js', 'sidepanel.css')) {
  $path = Join-Path $ExtensionRoot $required
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing staged extension file: $path" }
}
$manifestData = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
if ($manifestData.name -ne 'Codex Desktop Work') { throw "Unexpected local extension manifest name: $($manifestData.name)" }

try {
  $healthUri = ($Endpoint -replace '^ws:', 'http:') + '/healthz'
  $health = Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec 3
  if ($health.StatusCode -ne 200) { throw "Health check returned HTTP $($health.StatusCode)" }
} catch {
  throw "Codex Work app-server is not healthy at $Endpoint. Run start-codex-work-app-server.ps1 first. $($_.Exception.Message)"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { throw 'Node.js 22 or newer is required for the WebSocket smoke test.' }
$helper = Join-Path $PSScriptRoot 'lib\codex-work-rpc-smoke.cjs'
$args = @($helper, '--endpoint', $Endpoint)
if ($TurnSmoke) { $args += '--turn-smoke' }
& $node.Source @args
if ($LASTEXITCODE -ne 0) { throw "Codex Work RPC smoke failed with exit code $LASTEXITCODE." }

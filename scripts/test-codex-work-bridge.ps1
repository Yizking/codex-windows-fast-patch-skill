[CmdletBinding()]
param(
  [string]$Endpoint = 'ws://127.0.0.1:43123/ws',
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
$publicKey = [Convert]::FromBase64String([string]$manifestData.key)
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $digest = $sha.ComputeHash($publicKey) } finally { $sha.Dispose() }
$idBuilder = [System.Text.StringBuilder]::new()
for ($index = 0; $index -lt 16; $index++) {
  [void]$idBuilder.Append([char](97 + ($digest[$index] -shr 4)))
  [void]$idBuilder.Append([char](97 + ($digest[$index] -band 15)))
}
$extensionId = $idBuilder.ToString()

try {
  $endpointUri = [Uri]$Endpoint
  $healthUri = "http://127.0.0.1:$($endpointUri.Port)/healthz"
  $health = Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec 3
  if ($health.StatusCode -ne 200) { throw "Health check returned HTTP $($health.StatusCode)" }
} catch {
  throw "Codex Work bridge is not healthy at $Endpoint. Run start-codex-work-app-server.ps1 first. $($_.Exception.Message)"
}

$origin = "chrome-extension://$extensionId"
$client = [System.Net.WebSockets.ClientWebSocket]::new()
$client.Options.AddSubProtocol('codex-jsonrpc-v1')
$client.Options.SetRequestHeader('Origin', $origin)
$tokenSource = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes($(if ($TurnSmoke) { 2 } else { 1 })))
$token = $tokenSource.Token
$requestId = 0

function Send-RpcRequest {
  param([string]$Method, [object]$Params)
  $script:requestId++
  $message = @{ jsonrpc = '2.0'; id = $script:requestId; method = $Method; params = $Params } | ConvertTo-Json -Depth 50 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
  $segment = [System.ArraySegment[byte]]::new($bytes)
  $null = $client.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult()
  return $script:requestId
}

function Receive-RpcMessage {
  $stream = [System.IO.MemoryStream]::new()
  try {
    do {
      $buffer = New-Object byte[] 16384
      $segment = [System.ArraySegment[byte]]::new($buffer)
      $result = $client.ReceiveAsync($segment, $token).GetAwaiter().GetResult()
      if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'Bridge closed the WebSocket unexpectedly.' }
      if ($stream.Length + $result.Count -gt 8MB) { throw 'RPC response exceeded the 8 MiB limit.' }
      if ($result.Count -gt 0) { $stream.Write($buffer, 0, $result.Count) }
    } while (-not $result.EndOfMessage)
    $json = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    return $json | ConvertFrom-Json
  } finally { $stream.Dispose() }
}

function Wait-RpcResponse {
  param([int]$Id, [System.Collections.Generic.List[string]]$Deltas)
  while ($true) {
    $message = Receive-RpcMessage
    if ($message.method -eq 'item/agentMessage/delta' -and $null -ne $Deltas) { $Deltas.Add([string]$message.params.delta) }
    if ($message.method -eq 'turn/completed' -and $null -ne $Deltas) { return $message }
    if ($message.id -eq $Id) {
      if ($message.error) { throw "RPC failed: $($message.error.message)" }
      return $message
    }
  }
}

try {
  $null = $client.ConnectAsync($endpointUri, $token).GetAwaiter().GetResult()
  $id = Send-RpcRequest 'initialize' @{ clientInfo = @{ name = 'codex-work-bridge-smoke'; version = '0.1.0' } }
  $null = Wait-RpcResponse $id $null

  $id = Send-RpcRequest 'model/list' @{ includeHidden = $true; limit = 100 }
  $modelResponse = Wait-RpcResponse $id $null
  $models = @($modelResponse.result.data)
  if ($models.Count -eq 0) { throw 'model/list returned no models.' }
  $selected = $models | Where-Object { $_.isDefault } | Select-Object -First 1
  if (-not $selected) { $selected = $models[0] }
  $tier = 'default'
  if (@($selected.serviceTiers | Where-Object { $_.id -eq 'priority' }).Count -gt 0) { $tier = 'priority' }

  $threadParams = @{ model = $selected.id }
  if ($tier -ne 'default') { $threadParams.serviceTier = $tier }
  $id = Send-RpcRequest 'thread/start' $threadParams
  $threadResponse = Wait-RpcResponse $id $null
  $thread = $threadResponse.result
  if (-not $thread.thread.id -or -not $thread.modelProvider) { throw 'thread/start did not return a provider and thread id.' }

  if ($TurnSmoke) {
    $turnParams = @{
      threadId = $thread.thread.id
      input = @(@{ type = 'text'; text = 'Reply with exactly CODEX_WORK_BRIDGE_SMOKE_OK.' })
      effort = 'low'
    }
    if ($tier -ne 'default') { $turnParams.serviceTier = $tier }
    $deltas = [System.Collections.Generic.List[string]]::new()
    $id = Send-RpcRequest 'turn/start' $turnParams
    $turnComplete = Wait-RpcResponse -Id $id -Deltas $deltas
    if ($turnComplete.method -ne 'turn/completed') { $turnComplete = Wait-RpcResponse -Id -1 -Deltas $deltas }
    $reply = $deltas -join ''
    if ($turnComplete.params.turn.status -ne 'completed' -or $reply -notmatch 'CODEX_WORK_BRIDGE_SMOKE_OK') {
      throw 'Turn smoke did not receive the expected completed response marker.'
    }
  }

  [pscustomobject]@{
    endpoint = $Endpoint
    extensionId = $extensionId
    modelCount = $models.Count
    model = $thread.model
    modelProvider = $thread.modelProvider
    serviceTier = if ($thread.serviceTier) { $thread.serviceTier } else { $tier }
    turnSmoke = [bool]$TurnSmoke
  } | ConvertTo-Json -Compress
} finally {
  if ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
    try { $null = $client.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'smoke complete', [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch {}
  }
  $client.Dispose()
  $tokenSource.Dispose()
}

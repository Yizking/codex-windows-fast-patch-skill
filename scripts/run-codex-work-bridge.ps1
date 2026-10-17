[CmdletBinding()]
param(
  [int]$Port = 43123,
  [Parameter(Mandatory = $true)]
  [string]$ExtensionId,
  [Parameter(Mandatory = $true)]
  [string]$CodexCliPath,
  [string]$WorkRoot = 'D:\CodexData\codex-work-bridge'
)

$ErrorActionPreference = 'Stop'
$originExpected = "chrome-extension://$ExtensionId"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
$stopRequested = $false
$activeSocket = $null
$activeCodex = $null
$activeStderrTask = $null
$stderrPath = Join-Path $WorkRoot 'app-server.stderr.log'

function Close-HttpResponse {
  param([System.Net.HttpListenerContext]$Context, [int]$Status, [string]$Body = '')
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = 'text/plain; charset=utf-8'
  $Context.Response.ContentLength64 = $bytes.Length
  if ($bytes.Length -gt 0) { $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
  $Context.Response.Close()
}

function Start-CodexStdioServer {
  $start = [System.Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $CodexCliPath
  $start.Arguments = 'app-server --stdio'
  $start.WorkingDirectory = $env:USERPROFILE
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $start
  if (-not $process.Start()) { throw 'Codex app-server failed to start.' }
  $script:activeStderrTask = $process.StandardError.ReadToEndAsync()
  return $process
}

function Stop-ChildProcess {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try {
    if (-not $Process.HasExited) { $Process.Kill() }
    $Process.WaitForExit(3000) | Out-Null
  } catch {}
  try {
    if ($script:activeStderrTask -and $script:activeStderrTask.IsCompleted) {
      $stderr = $script:activeStderrTask.Result
      if (-not [string]::IsNullOrWhiteSpace($stderr)) { [System.IO.File]::AppendAllText($stderrPath, $stderr, [System.Text.Encoding]::UTF8) }
    }
  } catch {}
  $script:activeStderrTask = $null
  $Process.Dispose()
}

function Send-WebSocketText {
  param([System.Net.WebSockets.WebSocket]$Socket, [string]$Text, [System.Threading.CancellationToken]$Token)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $segment = [System.ArraySegment[byte]]::new($bytes)
  $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $Token).GetAwaiter().GetResult()
}

function Handle-QueuedHttpRequest {
  param([System.Net.HttpListenerContext]$Context)
  if ($Context.Request.Url.AbsolutePath -eq '/healthz' -and $Context.Request.HttpMethod -eq 'GET') {
    Close-HttpResponse $Context 200 'healthy'
    return $false
  }
  if ($Context.Request.Url.AbsolutePath -eq '/shutdown' -and $Context.Request.HttpMethod -eq 'POST' -and [string]::IsNullOrEmpty($Context.Request.Headers['Origin'])) {
    Close-HttpResponse $Context 200 'stopping'
    try { $listener.Stop() } catch {}
    return $true
  }
  Close-HttpResponse $Context 503 'busy'
  return $false
}

function Invoke-WebSocketBridge {
  param(
    [System.Net.WebSockets.WebSocket]$Socket,
    [System.Diagnostics.Process]$Process,
    [System.Threading.Tasks.Task[System.Net.HttpListenerContext]]$AcceptTask
  )

  $tokenSource = [System.Threading.CancellationTokenSource]::new()
  $messageBuffer = [System.IO.MemoryStream]::new()
  $receiveBytes = New-Object byte[] 16384
  $receiveSegment = [System.ArraySegment[byte]]::new($receiveBytes)
  $receiveTask = $Socket.ReceiveAsync($receiveSegment, $tokenSource.Token)
  $stdoutTask = $Process.StandardOutput.ReadLineAsync()
  $shutdown = $false

  try {
    while (-not $shutdown -and $Socket.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $Process.HasExited) {
      $completed = [System.Threading.Tasks.Task]::WhenAny($receiveTask, $stdoutTask, $AcceptTask).GetAwaiter().GetResult()

      if ($completed -eq $AcceptTask) {
        try {
          $context = $AcceptTask.Result
          $AcceptTask = $listener.GetContextAsync()
          $shutdown = Handle-QueuedHttpRequest $context
          continue
        } catch {
          if (-not $listener.IsListening) { $shutdown = $true; continue }
          throw
        }
      }

      if ($completed -eq $stdoutTask) {
        $line = $stdoutTask.Result
        if ($null -eq $line) { break }
        if ($line.Length -gt 0) { Send-WebSocketText $Socket $line $tokenSource.Token }
        $stdoutTask = $Process.StandardOutput.ReadLineAsync()
        continue
      }

      if ($completed -eq $receiveTask) {
        $result = $receiveTask.Result
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
        if ($result.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) { throw 'Only JSON text messages are supported.' }
        if ($messageBuffer.Length + $result.Count -gt 8MB) { throw 'WebSocket message exceeds the 8 MiB limit.' }
        if ($result.Count -gt 0) { $messageBuffer.Write($receiveBytes, 0, $result.Count) }

        if ($result.EndOfMessage) {
          $message = [System.Text.Encoding]::UTF8.GetString($messageBuffer.ToArray())
          $messageBuffer.SetLength(0)
          if ($message -notmatch '^\s*\{.*\}\s*$') { throw 'Expected one JSON-RPC object per WebSocket message.' }
          $Process.StandardInput.WriteLine($message)
          $Process.StandardInput.Flush()
        }
        $receiveTask = $Socket.ReceiveAsync($receiveSegment, $tokenSource.Token)
      }
    }
  } finally {
    $tokenSource.Cancel()
    $messageBuffer.Dispose()
    $tokenSource.Dispose()
  }

  return [pscustomobject]@{ Shutdown = $shutdown; AcceptTask = $AcceptTask }
}

$acceptTask = $listener.GetContextAsync()
try {
  while ($listener.IsListening -and -not $stopRequested) {
    $context = $acceptTask.GetAwaiter().GetResult()
    $acceptTask = $listener.GetContextAsync()
    $path = $context.Request.Url.AbsolutePath
    if ($path -eq '/healthz' -and $context.Request.HttpMethod -eq 'GET') {
      Close-HttpResponse $context 200 'healthy'
      continue
    }
    if ($path -eq '/shutdown' -and $context.Request.HttpMethod -eq 'POST' -and [string]::IsNullOrEmpty($context.Request.Headers['Origin'])) {
      Close-HttpResponse $context 200 'stopping'
      $stopRequested = $true
      try { $listener.Stop() } catch {}
      break
    }
    if ($path -ne '/ws' -or -not $context.Request.IsWebSocketRequest) {
      Close-HttpResponse $context 404 'not found'
      continue
    }

    $origin = $context.Request.Headers['Origin']
    if (-not [string]::Equals($origin, $originExpected, [StringComparison]::Ordinal)) {
      Close-HttpResponse $context 403 'origin rejected'
      continue
    }

    $webSocketContext = $context.AcceptWebSocketAsync('codex-jsonrpc-v1').GetAwaiter().GetResult()
    $activeSocket = $webSocketContext.WebSocket
    $activeCodex = Start-CodexStdioServer
    try {
      $bridgeResult = Invoke-WebSocketBridge $activeSocket $activeCodex $acceptTask
      $acceptTask = $bridgeResult.AcceptTask
      $stopRequested = $bridgeResult.Shutdown
    } catch {
      try { [System.IO.File]::AppendAllText($stderrPath, $_.Exception.Message + [Environment]::NewLine, [System.Text.Encoding]::UTF8) } catch {}
    } finally {
      Stop-ChildProcess $activeCodex
      $activeCodex = $null
      try { $activeSocket.Abort() } catch {}
      $activeSocket.Dispose()
      $activeSocket = $null
    }
  }
} catch [System.Net.HttpListenerException] {
  if (-not $stopRequested) { throw }
} finally {
  Stop-ChildProcess $activeCodex
  if ($activeSocket) { try { $activeSocket.Abort() } catch {}; $activeSocket.Dispose() }
  if ($listener.IsListening) { $listener.Stop() }
  $listener.Close()
}

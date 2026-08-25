<#
  Testa a deteccao de image target de ponta a ponta, sem celular.

  Chrome recebe um .y4m como camera; o engine so aceita facingMode exact:'environment',
  que a camera falsa nao oferece, entao um shim injetado antes do documento relaxa as
  restricoes 'exact'. O estado da pagina e lido pelo protocolo DevTools.
#>
param(
  [string]$Url  = 'http://localhost:8123/?debug=1',
  [string]$Y4m,
  [int]$WaitSeconds = 75,
  [int]$Throttle = 1
)

$ErrorActionPreference = 'Stop'
$tmp = Split-Path $PSCommandPath -Parent

function Send-Cdp($ws, $id, $method, $paramsJson) {
  $b = [Text.Encoding]::UTF8.GetBytes("{""id"":$id,""method"":""$method"",""params"":$paramsJson}")
  $s = New-Object System.ArraySegment[byte] (,$b)
  $ws.SendAsync($s, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                [System.Threading.CancellationToken]::None).Wait(10000) | Out-Null
}

function Recv-Cdp($ws) {
  $buf = New-Object byte[] 1048576
  $s = New-Object System.ArraySegment[byte] (,$buf)
  $sb = New-Object Text.StringBuilder
  do {
    $r = $ws.ReceiveAsync($s, [System.Threading.CancellationToken]::None)
    $r.Wait(30000) | Out-Null
    [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count))
  } while (-not $r.Result.EndOfMessage)
  $sb.ToString()
}

function Wait-Cdp($ws, $id) {
  for ($k = 0; $k -lt 40; $k++) {
    $r = Recv-Cdp $ws
    if ($r -match """id"":$id[,}]") { return ($r | ConvertFrom-Json) }
  }
  $null
}

Get-Process chrome -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 2

$prof = Join-Path $tmp 'chromeprofile3'
Remove-Item $prof -Recurse -Force -EA SilentlyContinue
$ua = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'

Start-Process "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" -ArgumentList @(
  '--remote-debugging-port=9222',
  "--user-data-dir=`"$prof`"",
  '--no-first-run', '--no-default-browser-check',
  '--use-fake-ui-for-media-stream',
  '--use-fake-device-for-media-stream',
  "--use-file-for-fake-video-capture=`"$Y4m`"",
  '--autoplay-policy=no-user-gesture-required',
  "--user-agent=`"$ua`"",
  '--window-size=500,860',
  'about:blank'
)
Start-Sleep -Seconds 6

$j = curl.exe -s 'http://localhost:9222/json' | ConvertFrom-Json
$page = $j | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait(10000) | Out-Null

# Relaxa restricoes 'exact' que a camera falsa nao consegue satisfazer.
$shim = @'
(() => {
  const relax = (o) => {
    if (!o || typeof o !== 'object') return o
    for (const k of Object.keys(o)) {
      const v = o[k]
      if (v && typeof v === 'object') {
        if ('exact' in v) { o[k] = v.exact } else { relax(v) }
      }
    }
    return o
  }
  const md = navigator.mediaDevices
  const orig = md.getUserMedia.bind(md)
  md.getUserMedia = (c) => {
    try { c = relax(JSON.parse(JSON.stringify(c))) } catch (e) {}
    return orig(c)
  }
})()
'@

Send-Cdp $ws 1 'Page.enable' '{}'
Wait-Cdp $ws 1 | Out-Null
Send-Cdp $ws 2 'Page.addScriptToEvaluateOnNewDocument' ('{"source":' + ($shim | ConvertTo-Json) + '}')
Wait-Cdp $ws 2 | Out-Null
if ($Throttle -gt 1) {
  Send-Cdp $ws 20 'Emulation.setCPUThrottlingRate' "{""rate"":$Throttle}"
  Wait-Cdp $ws 20 | Out-Null
  Write-Host "CPU limitada em ${Throttle}x"
}
Send-Cdp $ws 3 'Page.navigate' ('{"url":' + ($Url | ConvertTo-Json) + '}')
Wait-Cdp $ws 3 | Out-Null

Write-Host "navegou para $Url; aguardando $WaitSeconds s..."
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 10
  $t = (curl.exe -s 'http://localhost:9222/json' | ConvertFrom-Json |
        Where-Object { $_.url -like '*8123*' } | Select-Object -First 1).title
  Write-Host ("  " + $t)
  if ($t -match 'found=(?!-)') { Write-Host '  >>> DETECTOU' -ForegroundColor Green; break }
}

$expr = "(document.querySelector('.steps')||{innerText:'SEM OVERLAY'}).innerText"
Send-Cdp $ws 9 'Runtime.evaluate' ('{"expression":' + ($expr | ConvertTo-Json) + ',"returnByValue":true}')
$res = Wait-Cdp $ws 9
Write-Host ''
Write-Host '===== LOG DA PAGINA ====='
Write-Host $res.result.result.value
$ws.Dispose()

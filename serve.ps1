<#
.SYNOPSIS
  Servidor estatico para testar a experiencia de RA localmente.

.DESCRIPTION
  Suporta requisicoes Range (HTTP 206), necessarias para o navegador reproduzir e
  buscar dentro dos .mp4.

  A camera so e liberada em origem segura: https://... ou http://localhost.
  - No PC          : http://localhost:8080 funciona direto.
  - No celular     : HTTP na rede local NAO libera a camera. Veja README.md
                     ("Testar no celular") para as opcoes.

.PARAMETER Port
  Porta TCP. Padrao 8080.

.PARAMETER LocalOnly
  Escuta apenas em localhost (nao exige privilegio de administrador).
#>
[CmdletBinding()]
param(
  [int]$Port = 8080,
  [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$mime = @{
  '.html' = 'text/html; charset=utf-8'
  '.js'   = 'text/javascript; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.png'  = 'image/png'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.mp4'  = 'video/mp4'
  '.svg'  = 'image/svg+xml'
  '.ico'  = 'image/x-icon'
  '.wasm' = 'application/wasm'
}

$listener = New-Object System.Net.HttpListener
$prefixes = if ($LocalOnly) { @("http://localhost:$Port/") } else { @("http://+:$Port/") }

foreach ($p in $prefixes) { $listener.Prefixes.Add($p) }

try {
  $listener.Start()
} catch {
  if (-not $LocalOnly) {
    Write-Warning "Nao consegui escutar em http://+:$Port/ (precisa de admin). Caindo para localhost."
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
  } else { throw }
}

$ips = @()
if (-not $LocalOnly) {
  $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
         Select-Object -ExpandProperty IPAddress
}

Write-Host ''
Write-Host "  Servindo $root" -ForegroundColor Cyan
Write-Host "  -> http://localhost:$Port" -ForegroundColor Green
foreach ($ip in $ips) { Write-Host "  -> http://${ip}:$Port  (rede local, sem camera)" -ForegroundColor DarkGray }
Write-Host ''
Write-Host '  Ctrl+C para parar.' -ForegroundColor DarkGray
Write-Host ''

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    try {
      $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
      if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }

      $full = Join-Path $root $rel
      # Impede escapar da raiz via ../
      $fullResolved = [System.IO.Path]::GetFullPath($full)
      if (-not $fullResolved.StartsWith([System.IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)) {
        $res.StatusCode = 403; $res.Close(); continue
      }

      if (-not (Test-Path $fullResolved -PathType Leaf)) {
        $res.StatusCode = 404
        $body = [Text.Encoding]::UTF8.GetBytes("404 - $rel")
        $res.OutputStream.Write($body, 0, $body.Length)
        $res.Close()
        Write-Host "  404 $rel" -ForegroundColor DarkYellow
        continue
      }

      $ext = [System.IO.Path]::GetExtension($fullResolved).ToLowerInvariant()
      $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $res.Headers['Cache-Control'] = 'no-cache'
      $res.Headers['Accept-Ranges'] = 'bytes'

      $fs = [System.IO.File]::OpenRead($fullResolved)
      try {
        $total = $fs.Length
        $start = 0
        $end   = $total - 1

        $range = $req.Headers['Range']
        if ($range -and $range -match 'bytes=(\d*)-(\d*)') {
          $s = $matches[1]; $e = $matches[2]
          if ($s -ne '') {
            $start = [int64]$s
            if ($e -ne '') { $end = [int64]$e }
          } else {
            # bytes=-N : ultimos N bytes
            $start = [Math]::Max(0, $total - [int64]$e)
          }
          if ($start -gt $end -or $start -ge $total) {
            $res.StatusCode = 416
            $res.Headers['Content-Range'] = "bytes */$total"
            $res.Close(); continue
          }
          $res.StatusCode = 206
          $res.Headers['Content-Range'] = "bytes $start-$end/$total"
        }

        $length = $end - $start + 1
        $res.ContentLength64 = $length
        $fs.Position = $start

        $buffer = New-Object byte[] 262144
        $remaining = $length
        while ($remaining -gt 0) {
          $read = $fs.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
          if ($read -le 0) { break }
          $res.OutputStream.Write($buffer, 0, $read)
          $remaining -= $read
        }
      } finally { $fs.Dispose() }

      $res.Close()
    } catch [System.Net.HttpListenerException] {
      # cliente desconectou no meio do stream (comum com video)
    } catch {
      Write-Host "  ERRO $($_.Exception.Message)" -ForegroundColor Red
      try { $res.StatusCode = 500; $res.Close() } catch {}
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}

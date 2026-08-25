<#
.SYNOPSIS
  Reencoda os videos para uso em RA na web.

.DESCRIPTION
  Os originais estao em 2160x2700 - resolucao pensada para impressao, muito acima do
  que um plano de RA precisa. Na tela o poster ocupa poucas centenas de pixels, entao
  reduzir a largura corta o peso drasticamente sem diferenca visivel.

  Escolhas de encoding e por que:
    -c:v libx264      H.264 e o unico codec com suporte universal em iOS Safari + Android.
    -pix_fmt yuv420p  Sem isso o Safari se recusa a reproduzir.
    -profile:v main   Compativel com aparelhos antigos; High traria pouco ganho aqui.
    -movflags +faststart
                      Move o indice do MP4 para o inicio, para o video comecar a tocar
                      antes do download terminar. Essencial em rede movel.
    scale=W:-2        -2 mantem a proporcao e forca altura par (exigencia do yuv420p).

  Audio so e reencodado se a faixa existir; caso contrario o arquivo sai sem trilha.

.PARAMETER Width
  Largura de saida. Padrao 1080 (gera 1080x1350 nos arquivos 4:5).

.PARAMETER Crf
  Qualidade, 18-28. Menor = melhor e maior. Padrao 21.

  21 foi escolhido comparando recortes 1:1 do meio-tom contra o original: e o ponto em
  que a arte fica indistinguivel. Como os originais estavam absurdamente super-encodados
  (10-25 Mbps para clipes de 14 fps), mesmo esse CRF conservador corta ~90% do peso, e
  nao vale a pena subir para 26 para economizar mais 1 MB por arquivo.

.PARAMETER InPlace
  Substitui os arquivos em video/ apos reencodar (guarda os originais em video-original/).
#>
[CmdletBinding()]
param(
  [string]$FFmpeg   = 'ffmpeg',
  [string]$FFprobe  = 'ffprobe',
  [string]$SourceDir = (Join-Path $PSScriptRoot '..\video'),
  [string]$OutDir    = (Join-Path $PSScriptRoot '..\video-optimized'),
  [int]$Width       = 1080,
  [int]$Crf         = 21,
  [string]$Preset   = 'slow',
  [switch]$InPlace
)

$ErrorActionPreference = 'Stop'

$SourceDir = (Resolve-Path $SourceDir).Path
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path

$files = Get-ChildItem -Path $SourceDir -File -Filter *.mp4 | Sort-Object Name
if ($files.Count -eq 0) { throw "Nenhum .mp4 em $SourceDir" }

Write-Host ''
Write-Host "  Origem : $SourceDir"
Write-Host "  Destino: $OutDir"
Write-Host "  Config : largura $Width, crf $Crf, preset $Preset"
Write-Host ''

$totalBefore = 0
$totalAfter  = 0
$results     = @()

foreach ($f in $files) {
  $out = Join-Path $OutDir $f.Name

  # Existe faixa de audio?
  $audio = & $FFprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 $f.FullName 2>$null
  $hasAudio = -not [string]::IsNullOrWhiteSpace($audio)

  $args = @(
    '-hide_banner', '-loglevel', 'error', '-y',
    '-i', $f.FullName,
    '-vf', "scale=${Width}:-2",
    '-c:v', 'libx264',
    '-crf', "$Crf",
    '-preset', $Preset,
    '-profile:v', 'main',
    '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart'
  )
  if ($hasAudio) { $args += @('-c:a', 'aac', '-b:a', '128k', '-ac', '2') }
  else           { $args += '-an' }
  $args += $out

  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $FFmpeg @args
  if ($LASTEXITCODE -ne 0) { throw "ffmpeg falhou em $($f.Name)" }
  $sw.Stop()

  $before = $f.Length
  $after  = (Get-Item $out).Length
  $totalBefore += $before
  $totalAfter  += $after

  $results += [PSCustomObject]@{
    Arquivo = $f.Name
    AntesMB = [math]::Round($before / 1MB, 1)
    DepoisMB = [math]::Round($after / 1MB, 1)
    Reducao = "$([math]::Round((1 - $after / $before) * 100))%"
    Audio   = if ($hasAudio) { 'sim' } else { 'nao' }
    Seg     = [math]::Round($sw.Elapsed.TotalSeconds)
  }

  Write-Host ("  {0}  {1,6:N1} MB -> {2,6:N1} MB  ({3})" -f `
    $f.Name, ($before / 1MB), ($after / 1MB), $results[-1].Reducao)
}

Write-Host ''
$results | Format-Table -AutoSize
Write-Host ("  TOTAL: {0:N1} MB -> {1:N1} MB  (reducao de {2}%)" -f `
  ($totalBefore / 1MB), ($totalAfter / 1MB), [math]::Round((1 - $totalAfter / $totalBefore) * 100)) -ForegroundColor Green

if ($InPlace) {
  $backup = Join-Path (Split-Path $SourceDir -Parent) 'video-original'
  if (-not (Test-Path $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
  Write-Host ''
  Write-Host "  Movendo originais para $backup e instalando os otimizados..." -ForegroundColor Yellow
  foreach ($f in $files) {
    Move-Item $f.FullName (Join-Path $backup $f.Name) -Force
    Move-Item (Join-Path $OutDir $f.Name) (Join-Path $SourceDir $f.Name) -Force
  }
  Remove-Item $OutDir -Force -ErrorAction SilentlyContinue
  Write-Host '  Pronto.' -ForegroundColor Green
}

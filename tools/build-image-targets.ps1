<#
.SYNOPSIS
  Gera image targets no formato do 8th Wall Engine (open source) a partir da pasta STLL.

.DESCRIPTION
  Replica a saida do @8thwall/image-target-cli sem precisar de Node/npm/sharp.

  Para cada imagem gera:
    - <nome>_luminance.png  : grayscale, altura 640  -> UNICO arquivo que o engine carrega
    - <nome>_thumbnail.png  : altura 350             -> usado pela UI de scanner
    - <nome>.json           : metadata do image target (schema ImageTargetData, type PLANAR)
    - manifest.json         : indice consumido pelo app

  Usa o mesmo recorte 3:4 do CLI oficial, produzindo luminancia 480x640. O video ainda
  cobre o poster inteiro: o app amplia o plano pela razao originalWidth/cropWidth.
  Ver README.md.

.PARAMETER Full
  Tambem grava <nome>_original.png e <nome>_cropped.png (referencia de autoria, ~70 MB).
  Nao sao usados em runtime.
#>
[CmdletBinding()]
param(
  [string]$ImageDir  = (Join-Path $PSScriptRoot '..\..\stll'),
  [string]$VideoDir  = (Join-Path $PSScriptRoot '..\..\VIDEO'),
  [string]$OutDir    = (Join-Path $PSScriptRoot '..\image-targets'),
  [switch]$Full
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Constantes do image-target-cli (src/constants.json)
$MIN_WIDTH        = 480
$MIN_HEIGHT       = 640
$LUMINANCE_HEIGHT = 640
$THUMBNAIL_HEIGHT = 350

$ImageDir = (Resolve-Path $ImageDir).Path
$VideoDir = (Resolve-Path $VideoDir).Path
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path

Write-Host "Imagens : $ImageDir"
Write-Host "Videos  : $VideoDir"
Write-Host "Saida   : $OutDir"
Write-Host ''

# Redimensiona com alta qualidade. Se $Gray, aplica luma Rec.709 (equivale ao
# .grayscale() do sharp, que converte para o espaco b-w do libvips).
function Resize-Image {
  param(
    [System.Drawing.Image]$Source,
    [int]$TargetHeight,
    [int]$SrcX = 0,
    [int]$SrcY = 0,
    [int]$SrcW = 0,
    [int]$SrcH = 0,
    [switch]$Gray
  )

  if ($SrcW -le 0) { $SrcW = $Source.Width }
  if ($SrcH -le 0) { $SrcH = $Source.Height }

  $w = [int][Math]::Round($SrcW * ($TargetHeight / $SrcH), [MidpointRounding]::AwayFromZero)
  $h = $TargetHeight

  # Reduz pela metade ate chegar perto do alvo, antes do redimensionamento final.
  #
  # Estas artes sao cheias de reticula de meio-tom. Um salto direto de 2700 para 640 px
  # com bicubico nao filtra o suficiente: o kernel nao cobre pixels de origem bastante e
  # a trama vira moire, poluindo justamente as features que o rastreamento usa. Cada
  # halving faz media de blocos 2x2, agindo como filtro passa-baixa - o resultado se
  # aproxima do Lanczos3 que o sharp usa no CLI oficial, sem dependencia externa.
  $stage = $null
  while (($SrcH / 2) -ge $h -and ($SrcW / 2) -ge $w) {
    $halfW = [int][Math]::Max(1, [Math]::Floor($SrcW / 2))
    $halfH = [int][Math]::Max(1, [Math]::Floor($SrcH / 2))

    $next = New-Object System.Drawing.Bitmap($halfW, $halfH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $ng   = [System.Drawing.Graphics]::FromImage($next)
    try {
      $ng.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
      $ng.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $ng.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $ng.Clear([System.Drawing.Color]::White)
      $ng.DrawImage($Source, (New-Object System.Drawing.Rectangle(0, 0, $halfW, $halfH)),
                    $SrcX, $SrcY, $SrcW, $SrcH, [System.Drawing.GraphicsUnit]::Pixel)
    } finally { $ng.Dispose() }

    if ($stage) { $stage.Dispose() }
    $stage = $next
    $Source = $stage
    $SrcX = 0; $SrcY = 0; $SrcW = $halfW; $SrcH = $halfH
  }

  $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

    # Fundo branco: imagens com alpha nao viram preto no grayscale.
    $g.Clear([System.Drawing.Color]::White)

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)

    if ($Gray) {
      $cm = New-Object System.Drawing.Imaging.ColorMatrix
      $cm.Matrix00 = 0.2126; $cm.Matrix01 = 0.2126; $cm.Matrix02 = 0.2126
      $cm.Matrix10 = 0.7152; $cm.Matrix11 = 0.7152; $cm.Matrix12 = 0.7152
      $cm.Matrix20 = 0.0722; $cm.Matrix21 = 0.0722; $cm.Matrix22 = 0.0722
      $cm.Matrix33 = 1.0
      $cm.Matrix44 = 1.0

      $ia = New-Object System.Drawing.Imaging.ImageAttributes
      $ia.SetColorMatrix($cm)
      try {
        $g.DrawImage($Source, $rect, $SrcX, $SrcY, $SrcW, $SrcH,
                     [System.Drawing.GraphicsUnit]::Pixel, $ia)
      } finally { $ia.Dispose() }
    } else {
      $g.DrawImage($Source, $rect, $SrcX, $SrcY, $SrcW, $SrcH,
                   [System.Drawing.GraphicsUnit]::Pixel)
    }
  } finally {
    $g.Dispose()
    if ($stage) { $stage.Dispose() }
  }

  return $bmp
}

$now      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$entries  = @()
$warnings = @()

$files = Get-ChildItem -Path $ImageDir -File |
         Where-Object { $_.Extension -match '^\.(png|jpg|jpeg)$' } |
         Sort-Object Name

if ($files.Count -eq 0) { throw "Nenhuma imagem encontrada em $ImageDir" }

foreach ($file in $files) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

  $img = [System.Drawing.Image]::FromFile($file.FullName)
  try {
    $W = $img.Width
    $H = $img.Height

    # Recorte 3:4, identico ao getDefaultCrop() do CLI oficial (src/crop.js).
    #
    # O CLI NUNCA produz outra proporcao: mesmo no modo manual ele recalcula a altura como
    # width * 4/3. As constantes confirmam a intencao - luminanceHeight 640 com
    # minimumWidth 480 da exatamente 480x640. Usar o recorte cheio destas imagens 4:5
    # gerava 512x640, uma proporcao que a ferramenta oficial jamais emite.
    #
    # O video cobre o poster inteiro mesmo assim: o app amplia o plano usando a razao
    # entre originalWidth e a largura do recorte. Ver ar-video-plane em app.js.
    if (($W / 3) -gt ($H / 4)) {
      $cropW = [int][Math]::Round($H * 3 / 4, [MidpointRounding]::AwayFromZero)
      $cropH = $H
      $cropL = [int][Math]::Round(($W - $cropW) / 2, [MidpointRounding]::AwayFromZero)
      $cropT = 0
    } else {
      $cropW = $W
      $cropH = [int][Math]::Round($W * 4 / 3, [MidpointRounding]::AwayFromZero)
      $cropL = 0
      $cropT = [int][Math]::Round(($H - $cropH) / 2, [MidpointRounding]::AwayFromZero)
    }

    $crop = [ordered]@{
      left           = $cropL
      top            = $cropT
      width          = $cropW
      height         = $cropH
      isRotated      = $false
      originalWidth  = $W
      originalHeight = $H
    }

    # validateCrop() do CLI oficial
    $issues = @()
    if ($cropL -lt 0) { $issues += 'left negativo' }
    if ($cropT -lt 0) { $issues += 'top negativo' }
    if ($cropW -lt $MIN_WIDTH)  { $issues += "largura $cropW < minimo $MIN_WIDTH" }
    if ($cropH -lt $MIN_HEIGHT) { $issues += "altura $cropH < minimo $MIN_HEIGHT" }
    if (($cropT + $cropH) -gt $H) { $issues += "recorte excede a altura ($($cropT + $cropH) > $H)" }
    if (($cropL + $cropW) -gt $W) { $issues += "recorte excede a largura ($($cropL + $cropW) > $W)" }
    if ($issues.Count -gt 0) {
      throw "$($file.Name): crop invalido -> $($issues -join '; ')"
    }

    $resources = [ordered]@{
      thumbnailImage = "${name}_thumbnail.png"
      luminanceImage = "${name}_luminance.png"
    }

    $lum = Resize-Image -Source $img -TargetHeight $LUMINANCE_HEIGHT `
                        -SrcX $cropL -SrcY $cropT -SrcW $cropW -SrcH $cropH -Gray
    try   { $lum.Save((Join-Path $OutDir $resources.luminanceImage), [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $lum.Dispose() }

    $thumb = Resize-Image -Source $img -TargetHeight $THUMBNAIL_HEIGHT `
                          -SrcX $cropL -SrcY $cropT -SrcW $cropW -SrcH $cropH
    try   { $thumb.Save((Join-Path $OutDir $resources.thumbnailImage), [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $thumb.Dispose() }

    if ($Full) {
      $resources.originalImage = "${name}_original.png"
      $resources.croppedImage  = "${name}_cropped.png"
      # Crop e cheio, entao original e cropped tem o mesmo conteudo.
      Copy-Item $file.FullName (Join-Path $OutDir $resources.originalImage) -Force
      Copy-Item $file.FullName (Join-Path $OutDir $resources.croppedImage)  -Force
    }

    # Video correspondente: mesmo numero base da imagem.
    $videoFile = Get-ChildItem -Path $VideoDir -File |
                 Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $name } |
                 Select-Object -First 1

    if ($null -eq $videoFile) {
      $warnings += "SEM VIDEO para o target '$name' - sera ignorado pelo app."
      $videoPath = $null
    } else {
      $videoPath = "video/$($videoFile.Name)"
    }

    $data = [ordered]@{
      type       = 'PLANAR'
      properties = $crop
      # NOTA: imagePath e uma URL relativa a raiz do site, nao um caminho de arquivo.
      imagePath  = "image-targets/$($resources.luminanceImage)"
      metadata   = [ordered]@{ video = $videoPath }
      name       = $name
      resources  = $resources
      created    = $now
      updated    = $now
    }

    $json = $data | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText((Join-Path $OutDir "$name.json"), "$json`n", (New-Object System.Text.UTF8Encoding($false)))

    $entries += [ordered]@{
      name      = $name
      video     = $videoPath
      thumbnail = "image-targets/$($resources.thumbnailImage)"
    }

    $lumW = [int][Math]::Round($cropW * ($LUMINANCE_HEIGHT / $cropH), [MidpointRounding]::AwayFromZero)
    Write-Host ("  {0,-4} {1}x{2} -> crop {3}x{4} @{5},{6} -> lum {7}x{8}  video: {9}" -f `
      $name, $W, $H, $cropW, $cropH, $cropL, $cropT, $lumW, $LUMINANCE_HEIGHT, $(if ($videoPath) { Split-Path $videoPath -Leaf } else { '--' }))
  }
  finally { $img.Dispose() }
}

$manifest = [ordered]@{
  generated = $now
  targets   = $entries
}
$mJson = $manifest | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText((Join-Path $OutDir 'manifest.json'), "$mJson`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "OK: $($entries.Count) image targets gerados em $OutDir"
foreach ($w in $warnings) { Write-Warning $w }
if ($entries.Count -gt 32) {
  Write-Warning "O engine rastreia no maximo 32 targets simultaneos; voce tem $($entries.Count)."
}

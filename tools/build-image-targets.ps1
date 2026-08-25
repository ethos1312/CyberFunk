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

  Usa crop CHEIO (a imagem inteira) e nao o crop 3:4 default do CLI oficial, para que o
  plano de video cubra exatamente o poster. Ver README.md.

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
    [switch]$Gray
  )

  $w = [int][Math]::Round($Source.Width * ($TargetHeight / $Source.Height))
  $h = $TargetHeight

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
        $g.DrawImage($Source, $rect, 0, 0, $Source.Width, $Source.Height,
                     [System.Drawing.GraphicsUnit]::Pixel, $ia)
      } finally { $ia.Dispose() }
    } else {
      $g.DrawImage($Source, $rect, 0, 0, $Source.Width, $Source.Height,
                   [System.Drawing.GraphicsUnit]::Pixel)
    }
  } finally { $g.Dispose() }

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

    # Crop cheio: o video precisa cobrir o poster inteiro.
    $crop = [ordered]@{
      left           = 0
      top            = 0
      width          = $W
      height         = $H
      isRotated      = $false
      originalWidth  = $W
      originalHeight = $H
    }

    # validateCrop() do CLI oficial
    $issues = @()
    if ($W -lt $MIN_WIDTH)  { $issues += "largura $W < minimo $MIN_WIDTH" }
    if ($H -lt $MIN_HEIGHT) { $issues += "altura $H < minimo $MIN_HEIGHT" }
    if ($issues.Count -gt 0) {
      throw "$($file.Name): crop invalido -> $($issues -join '; ')"
    }

    $resources = [ordered]@{
      thumbnailImage = "${name}_thumbnail.png"
      luminanceImage = "${name}_luminance.png"
    }

    $lum = Resize-Image -Source $img -TargetHeight $LUMINANCE_HEIGHT -Gray
    try   { $lum.Save((Join-Path $OutDir $resources.luminanceImage), [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $lum.Dispose() }

    $thumb = Resize-Image -Source $img -TargetHeight $THUMBNAIL_HEIGHT
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

    $lumW = [int][Math]::Round($W * ($LUMINANCE_HEIGHT / $H))
    Write-Host ("  {0,-4} {1,5}x{2,-5} -> luminance {3}x{4}  video: {5}" -f `
      $name, $W, $H, $lumW, $LUMINANCE_HEIGHT, $(if ($videoPath) { Split-Path $videoPath -Leaf } else { '--' }))
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

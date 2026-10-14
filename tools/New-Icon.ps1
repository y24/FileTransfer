#Requires -Version 5.1
<#
.SYNOPSIS
    FileTransfer.ico（青い角丸の四角に、行き来する 2 本の矢印）を作る
.DESCRIPTION
    WPF で各サイズを描画し、PNG 形式のアイコンとしてまとめる。リポジトリの FileTransfer.ico を作り直すときだけ使う。
#>
param([string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'FileTransfer.ico'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

function New-IconPng {
    param([int]$Size)
    $scale = $Size / 16.0
    $visual = New-Object System.Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    $background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x00, 0x5F, 0xB8))
    $context.DrawRoundedRectangle($background, $null, (New-Object System.Windows.Rect 0, 0, $Size, $Size), (3.5 * $scale), (3.5 * $scale))
    $pen = New-Object System.Windows.Media.Pen ([System.Windows.Media.Brushes]::White), 1.4
    $pen.StartLineCap = 'Round'
    $pen.EndLineCap = 'Round'
    $pen.LineJoin = 'Round'
    $arrows = [System.Windows.Media.Geometry]::Parse('M4,6 L11.5,6 M9.5,3.75 L11.75,6 L9.5,8.25 M12,10 L4.5,10 M6.5,7.75 L4.25,10 L6.5,12.25')
    $context.PushTransform((New-Object System.Windows.Media.ScaleTransform $scale, $scale))
    $context.DrawGeometry($null, $pen, $arrows)
    $context.Pop()
    $context.Close()

    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $Size, $Size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = New-Object System.IO.MemoryStream
    $encoder.Save($stream)
    return , $stream.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = @($sizes | ForEach-Object { , (New-IconPng $_) })

$stream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter $stream
$writer.Write([uint16]0)              # reserved
$writer.Write([uint16]1)              # type: icon
$writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $writer.Write([byte]$dimension)   # width
    $writer.Write([byte]$dimension)   # height
    $writer.Write([byte]0)            # colors
    $writer.Write([byte]0)            # reserved
    $writer.Write([uint16]1)          # planes
    $writer.Write([uint16]32)         # bits per pixel
    $writer.Write([uint32]$images[$i].Length)
    $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($image in $images) { $writer.Write([byte[]]$image) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
Write-Output $Path

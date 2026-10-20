#Requires -Version 7.4
<#
Draws the window and shortcut icon: a list of sessions on a dark tile, with a spark for Claude. Writes the .ico with every size
Windows asks for and, with -PreviewPath, a sheet showing each size on a light and a dark background.
#>
param(
    [string]$IconPath = (Join-Path $PSScriptRoot '..\ClaudeSessions\ClaudeSessions.ico'),
    [string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$TileColor = [System.Drawing.Color]::FromArgb(50, 56, 69)
$RowColor = [System.Drawing.Color]::FromArgb(236, 233, 227)
$DotColor = [System.Drawing.Color]::FromArgb(140, 146, 158)
$SparkColor = [System.Drawing.Color]::FromArgb(217, 119, 87)

function New-RoundedRectangle([single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius)
{
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = [Math]::Min($Radius * 2, [Math]::Min($Width, $Height))

    if ($diameter -le 0)
    {
        $path.AddRectangle([System.Drawing.RectangleF]::new($X, $Y, $Width, $Height))
        return $path
    }

    $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $path
}

# Four points with curved, pinched sides.
function New-Spark([single]$CenterX, [single]$CenterY, [single]$Radius)
{
    $pinch = $Radius * 0.18
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $tips = @(
        [System.Drawing.PointF]::new($CenterX, $CenterY - $Radius)
        [System.Drawing.PointF]::new($CenterX + $Radius, $CenterY)
        [System.Drawing.PointF]::new($CenterX, $CenterY + $Radius)
        [System.Drawing.PointF]::new($CenterX - $Radius, $CenterY)
    )
    $insides = @(
        [System.Drawing.PointF]::new($CenterX + $pinch, $CenterY - $pinch)
        [System.Drawing.PointF]::new($CenterX + $pinch, $CenterY + $pinch)
        [System.Drawing.PointF]::new($CenterX - $pinch, $CenterY + $pinch)
        [System.Drawing.PointF]::new($CenterX - $pinch, $CenterY - $pinch)
    )

    for ($index = 0; $index -lt 4; $index++)
        { $path.AddBezier($tips[$index], $insides[$index], $insides[$index], $tips[($index + 1) % 4]) }

    $path.CloseFigure()
    $path
}

# Small sizes drop the status dots and keep whole pixels, so the rows stay crisp at 16 px.
function New-IconImage([int]$Size)
{
    $image = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.PixelOffsetMode = 'HighQuality'
    $isSmall = $Size -lt 32
    $unit = $Size / 16

    $tile = New-RoundedRectangle 0 0 $Size $Size ([Math]::Max(2, $Size * 0.2))
    $graphics.FillPath([System.Drawing.SolidBrush]::new($TileColor), $tile)

    $rowHeight = [Math]::Max(2, [Math]::Round(2 * $unit))
    $rowLeft = if ($isSmall) { [Math]::Round(3 * $unit) } else { 5.2 * $unit }
    $rowTops = @(6.2, 9.2, 12.2) | ForEach-Object { [Math]::Round($_ * $unit) }
    $rowWidths = @(6.4, 8.4, 7.2) | ForEach-Object { if ($isSmall) { [Math]::Round(($_ + 2) * $unit) } else { $_ * $unit } }

    for ($index = 0; $index -lt 3; $index++)
    {
        $row = New-RoundedRectangle $rowLeft $rowTops[$index] $rowWidths[$index] $rowHeight ($rowHeight / 2)
        $graphics.FillPath([System.Drawing.SolidBrush]::new($RowColor), $row)

        if (-not $isSmall)
        {
            $statusColor = if ($index -eq 0) { $SparkColor } else { $DotColor }
            $graphics.FillEllipse([System.Drawing.SolidBrush]::new($statusColor), 2.6 * $unit, $rowTops[$index], $rowHeight, $rowHeight)
        }
    }

    $sparkRadius = if ($isSmall) { 3.2 * $unit } else { 2.9 * $unit }
    $spark = New-Spark (12.1 * $unit) (3.9 * $unit) $sparkRadius
    $graphics.FillPath([System.Drawing.SolidBrush]::new($SparkColor), $spark)

    $graphics.Dispose()
    $image
}

function Get-PngBytes($Image)
{
    $stream = [IO.MemoryStream]::new()
    $Image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $stream.ToArray()
}

# An .ico is a directory of images; each entry here is a PNG, which Windows reads at every size.
function Save-Icon([string]$Path, [hashtable]$PngBySize)
{
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$Sizes.Count)
    $offset = 6 + 16 * $Sizes.Count

    foreach ($size in $Sizes)
    {
        $dimension = if ($size -ge 256) { 0 } else { $size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$PngBySize[$size].Length)
        $writer.Write([uint32]$offset)
        $offset += $PngBySize[$size].Length
    }

    foreach ($size in $Sizes)
        { $writer.Write([byte[]]$PngBySize[$size]) }

    $writer.Flush()
    [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Path), $stream.ToArray())
    $writer.Dispose()
}

function Save-Preview([string]$Path, [hashtable]$ImageBySize)
{
    $padding = 16
    [int]$width = ($Sizes | Measure-Object -Sum).Sum + $padding * ($Sizes.Count + 1)
    [int]$rowHeight = 256 + $padding * 2
    $preview = [System.Drawing.Bitmap]::new($width, $rowHeight * 2)
    $graphics = [System.Drawing.Graphics]::FromImage($preview)
    $backgrounds = @([System.Drawing.Color]::FromArgb(243, 243, 243), [System.Drawing.Color]::FromArgb(32, 32, 32))

    for ($row = 0; $row -lt 2; $row++)
    {
        $graphics.FillRectangle([System.Drawing.SolidBrush]::new($backgrounds[$row]), 0, $row * $rowHeight, $width, $rowHeight)
        $x = $padding

        foreach ($size in $Sizes)
        {
            $graphics.DrawImageUnscaled($ImageBySize[$size], $x, $row * $rowHeight + $padding + 256 - $size)
            $x += $size + $padding
        }
    }

    $graphics.Dispose()
    $preview.Save([IO.Path]::GetFullPath($Path), [System.Drawing.Imaging.ImageFormat]::Png)
    $preview.Dispose()
}

$imageBySize = @{}
$pngBySize = @{}

foreach ($size in $Sizes)
{
    $imageBySize[$size] = New-IconImage $size
    $pngBySize[$size] = Get-PngBytes $imageBySize[$size]
}

Save-Icon $IconPath $pngBySize

if ($PreviewPath)
    { Save-Preview $PreviewPath $imageBySize }

# Draws the Mellow icons and writes them as .ico files:
#  - the app icon (rounded square with three soft lines);
#  - the document icon for associated files (a page with the app icon as a badge
#    in the top-left corner).
param(
    [string]$Out = "$PSScriptRoot\..\windows\runner\resources\app_icon.ico",
    [string]$DocOut = "$PSScriptRoot\..\windows\runner\resources\document.ico"
)

Add-Type -AssemblyName System.Drawing

function New-RoundedPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Color([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

# Draws the app mark into the square (x, y, side) of $g.
function Draw-AppMark($g, [float]$x, [float]$y, [float]$side) {
    $k = $side / 256.0
    $back = New-RoundedPath ($x + 16 * $k) ($y + 16 * $k) (224 * $k) (224 * $k) (64 * $k)
    $g.FillPath((New-Object System.Drawing.SolidBrush (Color 103 80 164)), $back)
    $line = New-Object System.Drawing.SolidBrush (Color 234 221 255)
    foreach ($row in @(@(84, 112), @(120, 88), @(156, 60))) {
        $bar = New-RoundedPath ($x + 72 * $k) ($y + $row[0] * $k) ($row[1] * $k) (20 * $k) (10 * $k)
        $g.FillPath($line, $bar)
    }
}

# A white page with a folded corner and grey text lines, badge top-left.
function Draw-Document($g, [int]$size) {
    $s = $size / 256.0
    $left = 44 * $s; $top = 12 * $s; $right = 220 * $s; $bottom = 244 * $s; $fold = 52 * $s
    $page = New-Object System.Drawing.Drawing2D.GraphicsPath
    $page.AddLine($left, $top, $right - $fold, $top)
    $page.AddLine($right - $fold, $top, $right, $top + $fold)
    $page.AddLine($right, $top + $fold, $right, $bottom)
    $page.AddLine($right, $bottom, $left, $bottom)
    $page.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush (Color 255 255 255)), $page)
    $pen = New-Object System.Drawing.Pen ((Color 160 160 160)), ([Math]::Max(1.0, 4 * $s))
    $pen.LineJoin = 'Round'
    $g.DrawPath($pen, $page)

    $corner = New-Object System.Drawing.Drawing2D.GraphicsPath
    $corner.AddLine($right - $fold, $top, $right - $fold, $top + $fold)
    $corner.AddLine($right - $fold, $top + $fold, $right, $top + $fold)
    $corner.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush (Color 228 228 228)), $corner)
    $g.DrawPath($pen, $corner)

    # Text lines; the top ones start right of the badge.
    $ink = New-Object System.Drawing.SolidBrush (Color 150 150 150)
    $lines = @(@(128, 80, 76), @(128, 112, 64), @(76, 144, 116), @(76, 176, 116), @(76, 208, 80))
    if ($size -lt 32) { $lines = @(@(76, 152, 116), @(76, 192, 116)) }
    foreach ($l in $lines) {
        $h = [Math]::Max(1.0, 12 * $s)
        $g.FillPath($ink, (New-RoundedPath ($l[0] * $s) ($l[1] * $s) ($l[2] * $s) $h ($h / 2)))
    }

    # App badge in the top-left corner, overlapping the page edge.
    $badge = if ($size -lt 32) { 150 * $s } else { 112 * $s }
    Draw-AppMark $g 0 0 $badge
}

function New-IconPng([int]$size, [string]$kind) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    if ($kind -eq 'doc') { Draw-Document $g $size } else { Draw-AppMark $g 0 0 $size }
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

function Write-Ico([string]$path, [string]$kind) {
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $images = foreach ($s in $sizes) { , (New-IconPng $s $kind) }
    $fs = [System.IO.File]::Create((Resolve-Path (Split-Path $path)).Path + '\' + (Split-Path $path -Leaf))
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$images[$i].Length); $bw.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($img in $images) { $bw.Write([byte[]]$img) }
    $bw.Close()
    "icon written: $path"
}

Write-Ico $Out 'app'
Write-Ico $DocOut 'doc'

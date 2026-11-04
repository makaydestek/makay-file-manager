Add-Type -AssemblyName System.Drawing

# Makay Dosya Yoneticisi - ikon alternatifleri (4 tasarim)
# Cikti: tool\icon_options\ikon_A..D.png + birlesik onizleme ikon_onizleme.png

$out = 'D:\MakayFileManager\tool\icon_options'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Get-RoundPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function Draw-Folder([System.Drawing.Graphics]$g, [float]$x, [float]$y, [float]$w, [float]$h, [System.Drawing.Brush]$brush) {
  $r = [Math]::Min($w, $h) * 0.08
  $tab = Get-RoundPath $x $y ($w * 0.40) ($h * 0.34) $r
  $g.FillPath($brush, $tab)
  $body = Get-RoundPath $x ($y + $h * 0.16) $w ($h * 0.84) $r
  $g.FillPath($brush, $body)
}

function Draw-Letter([System.Drawing.Graphics]$g, [string]$text, [float]$cy, [float]$size, [System.Drawing.Color]$color) {
  $f = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = 'Center'
  $fmt.LineAlignment = 'Center'
  $rect = New-Object System.Drawing.RectangleF(0, ($cy - $size), 512, ($size * 2))
  $g.DrawString($text, $f, (New-Object System.Drawing.SolidBrush($color)), $rect, $fmt)
}

function New-Canvas([System.Drawing.Color]$bg1, [System.Drawing.Color]$bg2, [bool]$horizontal) {
  $b = New-Object System.Drawing.Bitmap(512, 512)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  if ($horizontal) {
    $p1 = New-Object System.Drawing.Point(0, 0); $p2 = New-Object System.Drawing.Point(512, 512)
  } else {
    $p1 = New-Object System.Drawing.Point(0, 0); $p2 = New-Object System.Drawing.Point(0, 512)
  }
  $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($p1, $p2, $bg1, $bg2)
  $g.FillRectangle($bg, 0, 0, 512, 512)
  return @($b, $g)
}

# ---------------- Tasarim A: Mavi gradyan monogram ----------------
$ab = [System.Drawing.Color]::FromArgb(255, 99, 102, 241)
$ab2 = [System.Drawing.Color]::FromArgb(255, 14, 165, 233)
$r = New-Canvas $ab $ab2 $true
$bA = $r[0]; $gA = $r[1]
$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
$sheet = Get-RoundPath 146 88 220 210 30
$gA.FillPath($white, $sheet)
Draw-Folder $gA 96 150 320 250 $white
Draw-Letter $gA 'M' 300 150 ([System.Drawing.Color]::FromArgb(255, 79, 70, 229))
$bA.Save("$out\ikon_A.png", [System.Drawing.Imaging.ImageFormat]::Png)
$gA.Dispose(); $bA.Dispose()

# ---------------- Tasarim B: Teal kimlik (modernize) ----------------
$r = New-Canvas ([System.Drawing.Color]::FromArgb(255, 15, 116, 110)) ([System.Drawing.Color]::FromArgb(255, 45, 212, 191)) $true
$bB = $r[0]; $gB = $r[1]
$sheetB = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
$sB = Get-RoundPath 170 86 172 200 26
$gB.FillPath($sheetB, $sB)
Draw-Folder $gB 106 140 300 250 $white
Draw-Letter $gB 'M' 290 140 ([System.Drawing.Color]::FromArgb(255, 15, 116, 110))
$bB.Save("$out\ikon_B.png", [System.Drawing.Imaging.ImageFormat]::Png)
$gB.Dispose(); $bB.Dispose()

# ---------------- Tasarim C: Koyu neon ----------------
$r = New-Canvas ([System.Drawing.Color]::FromArgb(255, 31, 41, 55)) ([System.Drawing.Color]::FromArgb(255, 11, 18, 32)) $false
$bC = $r[0]; $gC = $r[1]
$shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 0, 0, 0))
$sh = Get-RoundPath 112 164 300 250 30
$gC.FillPath($shadow, $sh)
$fg1 = [System.Drawing.Color]::FromArgb(255, 34, 211, 238)
$fg2 = [System.Drawing.Color]::FromArgb(255, 37, 99, 235)
$fp1 = New-Object System.Drawing.Point(106, 150); $fp2 = New-Object System.Drawing.Point(406, 400)
$fgrad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($fp1, $fp2, $fg1, $fg2)
Draw-Folder $gC 106 150 300 250 $fgrad
$hi = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, 255, 255, 255))
$hip = Get-RoundPath 120 206 272 40 18
$gC.FillPath($hi, $hip)
Draw-Letter $gC 'M' 305 130 ([System.Drawing.Color]::FromArgb(255, 11, 18, 32))
$bC.Save("$out\ikon_C.png", [System.Drawing.Imaging.ImageFormat]::Png)
$gC.Dispose(); $bC.Dispose()

# ---------------- Tasarim D: Minimal iki renk (acik zemin) ----------------
$r = New-Canvas ([System.Drawing.Color]::FromArgb(255, 255, 255, 255)) ([System.Drawing.Color]::FromArgb(255, 226, 232, 240)) $false
$bD = $r[0]; $gD = $r[1]
$navy = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 30, 41, 59))
Draw-Folder $gD 106 150 300 250 $navy
$of1 = [System.Drawing.Color]::FromArgb(255, 249, 115, 22)
$of2 = [System.Drawing.Color]::FromArgb(255, 251, 146, 60)
$op1 = New-Object System.Drawing.Point(106, 235); $op2 = New-Object System.Drawing.Point(406, 400)
$ograd = New-Object System.Drawing.Drawing2D.LinearGradientBrush($op1, $op2, $of1, $of2)
$front = Get-RoundPath 106 235 300 165 26
$gD.FillPath($ograd, $front)
Draw-Letter $gD 'M' 325 120 ([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
$bD.Save("$out\ikon_D.png", [System.Drawing.Imaging.ImageFormat]::Png)
$gD.Dispose(); $bD.Dispose()

# ---------------- Birlesik onizleme (2x2 etiketli) ----------------
$cell = 440; $icon = 400; $gap = 20; $m = 20; $labelH = 50
$W = 2 * $cell + $gap + 2 * $m
$H = 2 * ($cell + $labelH) + $gap + 2 * $m
$canvas = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.Clear([System.Drawing.Color]::FromArgb(255, 248, 250, 252))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

$labels = @(
  'A - Mavi Gradyan Monogram',
  'B - Teal Kimlik (Modernize)',
  'C - Koyu Neon',
  'D - Minimal Iki Renk'
)
$files = @('ikon_A.png', 'ikon_B.png', 'ikon_C.png', 'ikon_D.png')
$lf = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$lb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 15, 23, 42))
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = 'Center'
$fmt.LineAlignment = 'Center'

for ($i = 0; $i -lt 4; $i++) {
  $col = $i % 2
  $row = [Math]::Floor($i / 2)
  $cx = $m + $col * ($cell + $gap) + ($cell - $icon) / 2
  $cy = $m + $row * ($cell + $labelH + $gap) + ($cell - $icon) / 2
  $img = [System.Drawing.Image]::FromFile("$out\$($files[$i])")
  $g.DrawImage($img, $cx, $cy, $icon, $icon)
  $img.Dispose()
  $lx = $m + $col * ($cell + $gap)
  $ly = $cy + $icon + 6
  $lh = $labelH - 10
  $lrect = New-Object System.Drawing.RectangleF([float]$lx, [float]$ly, [float]$cell, [float]$lh)
  $g.DrawString($labels[$i], $lf, $lb, $lrect, $fmt)
}
$canvas.Save("$out\ikon_onizleme.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $canvas.Dispose()

Write-Output "OK: $out\ikon_onizleme.png"
Get-ChildItem $out -Filter *.png | ForEach-Object { Write-Output $_.FullName }

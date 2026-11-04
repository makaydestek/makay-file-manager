Add-Type -AssemblyName System.Drawing

# Final ikon: Tasarim A (mavi gradyan monogram) + altinda "Dosya Yoneticisi" yazisi
# Cikti: 512 onizleme + android mipmap-*/ic_launcher.png (48/72/96/144/192)

$out = 'D:\MakayFileManager\tool\icon_options'
$root = 'D:\MakayFileManager\android\app\src\main\res'
$text = 'Dosya Y' + [char]0x00F6 + 'netici' + 'si'

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

# ---- 512x512 final ikon ----
$b = New-Object System.Drawing.Bitmap(512, 512)
$g = [System.Drawing.Graphics]::FromImage($b)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

$p1 = New-Object System.Drawing.Point(0, 0)
$p2 = New-Object System.Drawing.Point(512, 512)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  $p1, $p2,
  [System.Drawing.Color]::FromArgb(255, 99, 102, 241),
  [System.Drawing.Color]::FromArgb(255, 14, 165, 233))
$g.FillRectangle($bg, 0, 0, 512, 512)

$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))

# Belge (klasorun arkasinda ucurtme)
$sheet = Get-RoundPath 152 60 208 190 28
$g.FillPath($white, $sheet)

# Klasor (sekil A ile ayni oranlar, biraz buyutuldu)
$fx = 106; $fy = 110; $fw = 300; $fh = 230
$r = [Math]::Min($fw, $fh) * 0.07
$tab = Get-RoundPath $fx $fy ($fw * 0.40) ($fh * 0.34) $r
$g.FillPath($white, $tab)
$body = Get-RoundPath $fx ($fy + $fh * 0.16) $fw ($fh * 0.84) $r
$g.FillPath($white, $body)

# "M" monogrami (klasor govdesinin ortasinda, indigo)
$mcy = $fy + $fh * 0.16 + ($fh * 0.84) / 2
$mf = New-Object System.Drawing.Font('Segoe UI', 130, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$mfmt = New-Object System.Drawing.StringFormat
$mfmt.Alignment = 'Center'
$mfmt.LineAlignment = 'Center'
$mrect = New-Object System.Drawing.RectangleF(0, [float]($mcy - 130), 512, 260)
$g.DrawString('M', $mf, (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 79, 70, 229))), $mrect, $mfmt)

# "Dosya Yoneticisi" yazisi: golge + beyaz, genislik 440'a sigdirilir
$tcy = 412
$sz = [float]60
$tf = New-Object System.Drawing.Font('Segoe UI', $sz, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel
)
while ($g.MeasureString($text, $tf).Width -gt 440 -and $sz -gt 30) {
  $tf.Dispose()
  $sz = $sz - 2
  $tf = New-Object System.Drawing.Font('Segoe UI', $sz, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
}
$trect = New-Object System.Drawing.RectangleF(0, [float]($tcy - $sz), 512, [float]($sz * 2))
$shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 10, 30, 70))
$tsh = New-Object System.Drawing.RectangleF(0, [float]($tcy - $sz + 4), 512, [float]($sz * 2))
$g.DrawString($text, $tf, $shadow, $tsh, $mfmt)
$g.DrawString($text, $tf, $white, $trect, $mfmt)
Write-Output "yazi boyutu: $sz px, genislik: $([Math]::Round($g.MeasureString($text, $tf).Width)) px"

$g.Dispose()
$b.Save("$out\ikon_final_512.png", [System.Drawing.Imaging.ImageFormat]::Png)

# ---- Tum density'lere olcekleyip uygula ----
$densities = @{
  'mipmap-mdpi'    = 48
  'mipmap-hdpi'    = 72
  'mipmap-xhdpi'   = 96
  'mipmap-xxhdpi'  = 144
  'mipmap-xxxhdpi' = 192
}
$src = [System.Drawing.Image]::FromFile("$out\ikon_final_512.png")
foreach ($kv in $densities.GetEnumerator()) {
  $size = [int]$kv.Value
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g2 = [System.Drawing.Graphics]::FromImage($bmp)
  $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g2.SmoothingMode = 'AntiAlias'
  $g2.DrawImage($src, 0, 0, $size, $size)
  $g2.Dispose()
  $path = "$root\$($kv.Key)\ic_launcher.png"
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output "yazildi: $path ($size x $size)"
}
$src.Dispose()
$b.Dispose()
Write-Output "OK"

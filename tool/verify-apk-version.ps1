# APK icindeki versionName'in VERSION.txt ile ayni oldugunu dogrular.
# Kullanim: powershell -File tools\verify-apk-version.ps1 -ApkPath APK\MakayCleaner_v1.0.94.apk -ExpectedVersion 1.0.94
param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ApkPath)) {
    Write-Error "APK yok: $ApkPath"
    exit 1
}

$aapt = $null
$roots = @()
if ($env:ANDROID_HOME) { $roots += $env:ANDROID_HOME }
if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
$roots += 'C:\Android\Sdk'
$roots += 'C:\android\sdk'
foreach ($root in $roots) {
    if (-not $root) { continue }
    $bt = Join-Path $root 'build-tools'
    if (-not (Test-Path $bt)) { continue }
    $hit = Get-ChildItem -Path $bt -Recurse -Filter aapt.exe -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($hit) { $aapt = $hit.FullName; break }
}

if (-not $aapt) {
    Write-Output "UYARI: aapt bulunamadi; APK surum dogrulaması atlandı."
    exit 0
}

$out = & $aapt dump badging $ApkPath 2>$null | Out-String
$m = [regex]::Match($out, "versionName='([^']+)'")
if (-not $m.Success) {
    Write-Error "APK versionName okunamadi: $ApkPath"
    exit 1
}
$actual = $m.Groups[1].Value.Trim()
if ($actual -ne $ExpectedVersion.Trim()) {
    Write-Error "APK surum uyusmazligi: APK=$actual beklenen=$ExpectedVersion"
    exit 1
}

$codeM = [regex]::Match($out, "versionCode='([^']+)'")
$code = if ($codeM.Success) { $codeM.Groups[1].Value } else { '?' }
Write-Output "APK surum dogrulandi: versionName=$actual versionCode=$code"
exit 0

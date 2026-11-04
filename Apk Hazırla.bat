@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set REPO=makaydestek/makay-file-manager
set RELEASE_URL=https://github.com/%REPO%/releases/tag/

if not exist "APK" mkdir "APK"

echo Surum artiriliyor...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Join-Path '%~dp0' 'version.properties';" ^
  "$name = '1.0.0'; $code = 1;" ^
  "if (Test-Path $p) {" ^
  "  Get-Content $p | ForEach-Object {" ^
  "    if ($_ -match '^VERSION_NAME=(.+)$') { $name = $Matches[1].Trim() }" ^
  "    if ($_ -match '^VERSION_CODE=(.+)$') { $code = [int]$Matches[1].Trim() }" ^
  "  }" ^
  "}" ^
  "$parts = $name.Split('.');" ^
  "if ($parts.Length -lt 3) { $parts = @('1','0','0') }" ^
  "$parts[2] = [string](([int]$parts[2]) + 1);" ^
  "$name = $parts[0] + '.' + $parts[1] + '.' + $parts[2];" ^
  "$code = $code + 1;" ^
  "[IO.File]::WriteAllText($p, ('VERSION_NAME=' + $name + [Environment]::NewLine + 'VERSION_CODE=' + $code + [Environment]::NewLine));" ^
  "$pp = Join-Path '%~dp0' 'pubspec.yaml';" ^
  "$c = [IO.File]::ReadAllText($pp);" ^
  "$c = [regex]::Replace($c, '(?m)^version: .+$', ('version: ' + $name + '+' + $code));" ^
  "[IO.File]::WriteAllText($pp, $c);" ^
  "Write-Output $name" > "%TEMP%\mf_ver.txt"
set /p VER=<"%TEMP%\mf_ver.txt"
if "%VER%"=="" (
  echo.
  echo [HATA] Surum okunamadi - version.properties bozuk olabilir.
  pause
  exit /b 1
)
echo Yeni surum: %VER%

echo.
echo [0/5] Imza anahtari keystore dogrulaniyor...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\keystore_guard.ps1"
if errorlevel 1 (
  echo.
  echo [HATA] Imza anahtari bozulmus ya da degistirilmis! Derleme durduruldu.
  echo        Keystore asla degistirilmez ve silinmez - bu haliyle imzalanan
  echo        APK, mevcut kullanicilara kurulamaz.
  echo        Onarim icin:  powershell -File tool\keystore_guard.ps1 -Fix
  pause
  exit /b 1
)

echo.
echo [1/5] APK derleniyor (tek yapilandirma, birkac dakika surebilir)...
call flutter build apk --release
if errorlevel 1 (
  echo.
  echo [HATA] APK derlemesi basarisiz oldu! Yukaridaki hatalara bakin.
  pause
  exit /b 1
)

set OUT=build\app\outputs\flutter-apk\app-release.apk
if not exist "%OUT%" (
  echo.
  echo [HATA] Cikti APK bulunamadi: %OUT%
  pause
  exit /b 1
)

rem Not: if blogu icinde echo satirlarinda parantez KULLANILMAZ; cmd
rem parantezli blogu parse edemeden betigi o satirda keser.
copy /y "%OUT%" "APK\MakayFileManager-%VER%.apk" >nul
if not exist "APK\MakayFileManager-%VER%.apk" (
  echo [HATA] APK kopyalanamadi - APK klasorune yazma izni yok?
  pause
  exit /b 1
)

rem R8 obfuscation haritasi - release APK'nin stack trace'leri buradan
rem cozulebilir. APK ile ayni klasorde (surumli adla) ve GitHub Release
rem asset'i olarak yayinlanir.
set MAPSRC=build\app\outputs\mapping\release\mapping.txt
if exist "%MAPSRC%" (
  copy /y "%MAPSRC%" "APK\MakayFileManager-%VER%-mapping.txt" >nul
) else (
  echo [UYARI] R8 mapping.txt bulunamadi - stack trace cozulemez.
)

echo.
echo [2/5] SHA256 ozeti hazirlaniyor...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$apk = Join-Path '%~dp0' 'APK\MakayFileManager-%VER%.apk';" ^
  "$h = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower();" ^
  "[IO.File]::WriteAllText(($apk + '.sha256'), ($h + '  ' + (Split-Path $apk -Leaf) + [Environment]::NewLine));" ^
  "Write-Output ('SHA256: ' + $h)"
if errorlevel 1 (
  echo [HATA] SHA256 ozeti hazirlanamadi.
  pause
  exit /b 1
)

echo.
echo [3/5] Eski yerel surumler temizleniyor...
for %%F in ("APK\MakayFileManager-*.apk") do (
  if /i not "%%~nxF"=="MakayFileManager-%VER%.apk" del /q "%%F" >nul 2>&1
)
for %%F in ("APK\MakayFileManager-*.apk.sha256") do (
  if /i not "%%~nxF"=="MakayFileManager-%VER%.apk.sha256" del /q "%%F" >nul 2>&1
)
for %%F in ("APK\MakayFileManager-*-mapping.txt") do (
  if /i not "%%~nxF"=="MakayFileManager-%VER%-mapping.txt" del /q "%%F" >nul 2>&1
)

echo.
echo [4/5] Kod deposuna yukleniyor (git)...
if not exist "%~dp0tool\git_commit.cmd" (
  echo [HATA] tool\git_commit.cmd yok - yayin kimligi kurulamadi.
  pause
  exit /b 1
)
call "%~dp0tool\git_identity.cmd"
git add "version.properties" "pubspec.yaml" >nul
git diff --cached --quiet >nul 2>&1
if errorlevel 1 (
  call "%~dp0tool\git_commit.cmd" -m "Yayin: MakayFileManager v%VER%"
  if errorlevel 1 (
    echo [HATA] Git commit basarisiz.
    pause
    exit /b 1
  )
)
git push origin main
if errorlevel 1 (
  echo.
  echo [HATA] GitHub'a gonderilemedi. Internet baglantinizi kontrol edip
  echo        elle su komutu calistirin:  git push origin main
  pause
  exit /b 1
)

echo.
echo [5/5] GitHub Release olusturuluyor...
gh release view "%VER%" >nul 2>&1
if errorlevel 1 goto :createrelease
rem gh bos argumani reddettigi icin mapping yalnizca varsa asset listesine katilir.
if exist "APK\MakayFileManager-%VER%-mapping.txt" (
  gh release upload "%VER%" "APK\MakayFileManager-%VER%.apk" "APK\MakayFileManager-%VER%.apk.sha256" "APK\MakayFileManager-%VER%-mapping.txt" --clobber
) else (
  echo [UYARI] mapping yok, APK + SHA-256 yukleniyor.
  gh release upload "%VER%" "APK\MakayFileManager-%VER%.apk" "APK\MakayFileManager-%VER%.apk.sha256" --clobber
)
if errorlevel 1 (
  echo [HATA] Release varliklari yuklenemedi.
  pause
  exit /b 1
)
goto :verifyrelease
:createrelease
rem Baslik ve aciklama bos birakilir: GitHub sayfayi etiket + commit
rem mesaji ("Yayin: MakayFileManager v...") biciminde gosterir.
gh api -X POST repos/:owner/:repo/releases -f tag_name=%VER%
if errorlevel 1 (
  echo.
  echo [HATA] GitHub Release olusturulamadi. "gh auth status" ile
  echo        oturumu kontrol edin.
  pause
  exit /b 1
)
if exist "APK\MakayFileManager-%VER%-mapping.txt" (
  gh release upload "%VER%" "APK\MakayFileManager-%VER%.apk" "APK\MakayFileManager-%VER%.apk.sha256" "APK\MakayFileManager-%VER%-mapping.txt"
) else (
  gh release upload "%VER%" "APK\MakayFileManager-%VER%.apk" "APK\MakayFileManager-%VER%.apk.sha256"
)
if errorlevel 1 (
  echo [HATA] Release varliklari - APK, sha256 veya mapping yuklenemedi.
  pause
  exit /b 1
)
:verifyrelease
rem Yuklemenin gerceklestigini dogrula (sessiz basarisizlik olmasin).
gh release view "%VER%" --json assets -q ".assets | length" > "%TEMP%\mf_assets.txt"
set /p ASSETS=<"%TEMP%\mf_assets.txt"
if "%ASSETS%"=="" goto assetsok
rem Mapping varsa 3 varlik beklenir; yoksa APK + sha256 ile 2 de basarilidir.
set EXPECTED=3
if not exist "APK\MakayFileManager-%VER%-mapping.txt" set EXPECTED=2
if %ASSETS% LSS %EXPECTED% (
  echo.
  echo [HATA] Release %VER% olusturuldu ama dosyalar yuklenmedi - asset sayisi: %ASSETS%
  echo        Elle yuklemek icin:  gh release upload %VER% "APK\MakayFileManager-%VER%.apk" "APK\MakayFileManager-%VER%.apk.sha256" "APK\MakayFileManager-%VER%-mapping.txt" --clobber
  pause
  exit /b 1
)
:assetsok
echo Release dogrulandi (asset: %ASSETS%).

echo Eski GitHub surumleri siliniyor (yalnizca %VER% kalir)...
for /f "delims=" %%T in ('gh release list --json tagName -q ".[].tagName" 2^>nul') do (
  if not "%%T"=="%VER%" gh release delete "%%T" --yes --cleanup-tag >nul 2>&1
)

start "" "%~dp0APK"
echo.
echo ============================================================
echo  APK hazir   : APK\MakayFileManager-%VER%.apk
echo  GitHub      : %RELEASE_URL%%VER%
echo  Eski surumler: silindi (yalnizca %VER% kaldi)
echo ============================================================
pause
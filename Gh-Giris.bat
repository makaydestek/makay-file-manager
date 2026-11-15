@echo off
setlocal EnableExtensions
title Makay File Manager - GitHub Giris
cd /d "%~dp0"

set "PATH=%ProgramFiles%\GitHub CLI;%LocalAppData%\Programs\GitHub CLI;%PATH%"

REM ---------------------------------------------------------------------------
REM GitHub CLI oturumu.
REM
REM ONCE KURAL: Oturum zaten varsa HICIR BIR SEY yapilmaz. Daha once
REM "gh auth login" calistirmak tarayicida cihaz kodu + 2FA ekrani acar;
REM 2FA kodu yalnizca kimlik dogrulayici uygulamasi/recovery kodu ile
REM uretilir. O kod uretilemez ve otomatiklastirilamaz - bu tam olarak 2FA'nin
REM amacidir. Mevcut ve gecerli bir oturum varken hicbir koda gerek yoktur.
REM ---------------------------------------------------------------------------

echo.
echo ================================================
echo  GitHub CLI oturumu
echo ================================================
echo.

where gh >nul 2>&1
if errorlevel 1 (
  echo [HATA] gh bulunamadi.
  echo   Kurulum: winget install --id GitHub.cli
  pause
  exit /b 1
)

REM --- 1) Zaten girisli miyiz? (kimlik matrisi: repo, workflow) ------------
gh auth status >nul 2>&1
if not errorlevel 1 (
  echo [TAMAM] GitHub oturumu zaten var. Tarayici acilmaz, kod gerekmez.
  echo.
  gh auth status
  echo.
  echo Artik kok klasordeki APK hazirlama betigini calistirin.
  pause
  exit /b 0
)

echo [BILGI] Kayitli oturum yok. Giris deneniyor...
echo.

REM --- 2) Tercih: hazir bir Personal Access Token dosyasi -------------------
REM gh, tarayici/2FA akisini hic kullanmadan token ile giris yapabilir.
REM token.txt dosyasi varsa onu kullanilir (dosya icerigi asla ekrana basilmaz).
if exist "token.txt" (
  echo [BILGI] token.txt bulundu - dogrudan token ile giris yapiliyor.
  type "token.txt" | gh auth login --hostname github.com --git-protocol https --with-token
  if errorlevel 1 (
    echo [HATA] token gecersiz.
    pause
    exit /b 1
  )
  goto :OK
)

REM --- 3) Yoksa cihaz kodu akisi (kullanici 2FA kodunu girecek) --------------
echo   Kod XXXX-XXXX biciminde ASAGIDA gorunecek ve panoya kopyalanir.
echo   Tarayici acilinca:
echo     - kutuya kodu yapistirin
echo     - Authorize github cli
echo.
echo   NOT: 2FA acik hesaplarda tarayici ayrica 6 haneli dogrulama kodu
echo        ister; bu kod yalnizca kimlik dogrulayici uygulamanizdan (veya
echo        GitHub ayarlarindaki recovery kodundan) gelir.
echo.
pause

gh auth login -h github.com -p https -w -c -s "repo,read:org,gist,workflow"
if errorlevel 1 (
  echo.
  echo [HATA] Giris basarisiz.
  echo Alternatif: Personal Access Token olusturup token.txt olarak kaydedin,
  echo   sonra bu betigi tekrar calistirin (tarayici akisi atlanir).
  pause
  exit /b 1
)

:OK
echo.
gh auth status
echo.
echo [OK] Giris tamam. Simdi kok klasordeki APK hazirlama betigini calistirin.
pause
endlocal
exit /b 0

@echo off
REM ============================================================
REM  Yalnizca BU proje: call "%~dp0..\..\" degil, ayni tool\ altindan.
REM  Kullanim: call "%~dp0tool\git_commit.cmd" -m "mesaj" [-- dosya]
REM  Kimlik: tool\git_identity.cmd (proje ici). Global config yok.
REM ============================================================
setlocal EnableExtensions
if not exist "%~dp0git_identity.cmd" (
  echo [HATA] git_identity.cmd ayni tool\ klasorunde yok: %~dp0
  echo        Bu yardimci yalnizca uygulama klasorunde tutulmalidir.
  exit /b 1
)
call "%~dp0git_identity.cmd"
if not defined GIT_NAME (
  echo [HATA] GIT_NAME bos - tool\git_identity.cmd bozulmus olabilir.
  exit /b 1
)
if not defined GIT_EMAIL (
  echo [HATA] GIT_EMAIL bos - tool\git_identity.cmd bozulmus olabilir.
  exit /b 1
)
git -c "user.name=%GIT_NAME%" -c "user.email=%GIT_EMAIL%" commit %*
exit /b %ERRORLEVEL%
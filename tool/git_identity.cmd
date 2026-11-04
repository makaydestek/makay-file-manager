@echo off
REM ============================================================
REM  Yalnizca BU proje klasorunde yasamali (tool\git_identity.cmd).
REM  Dis konum / MakayShared / global git config KULLANILMAZ.
REM  git config --global ASLA yazilmaz.
REM ============================================================
set "GIT_NAME="
set "GIT_EMAIL="
for /f "delims=" %%A in ('git log -1 --format^="%%an" 2^>nul') do set "GIT_NAME=%%A"
for /f "delims=" %%A in ('git log -1 --format^="%%ae" 2^>nul') do set "GIT_EMAIL=%%A"
if not defined GIT_NAME set "GIT_NAME=makaydestek"
if not defined GIT_EMAIL set "GIT_EMAIL=makaydestek@users.noreply.github.com"
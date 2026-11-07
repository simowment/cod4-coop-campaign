@echo off
rem CoD4 Coop Campaign - join a friend's session. The game follows the host into their mission.
cd /d "%~dp0"
set NAME=
set /p NAME="Your name [%USERNAME%]: "
if "%NAME%"=="" set NAME=%USERNAME%
set HOST=
set /p HOST="Host address (IP or IP:port): "
if "%HOST%"=="" (
  echo You need the host's address.
  pause
  exit /b 1
)
echo Joining %HOST% as %NAME%...
start "" iw3sp.exe +set fs_game mods/coop +set coop_connect %HOST% +set coop_name "%NAME%"

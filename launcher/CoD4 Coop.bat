@echo off
rem CoD4 Coop Campaign - opens the launcher window (host a game or join a friend with a join code).
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0coop_launcher.ps1"

@echo off
rem CoD4 Coop Campaign - host a session. Your friends run "Coop - Join.bat" with your IP.
rem Needs UDP port 28970 reachable (LAN, a VPN like Tailscale/ZeroTier/Radmin, or a port forward).
cd /d "%~dp0"
set NAME=
set /p NAME="Your name [%USERNAME%]: "
if "%NAME%"=="" set NAME=%USERNAME%
echo.
echo Missions: killhouse cargoship coup blackout armada bog_a hunted ac130 bog_b airlift aftermath
echo           village_assault scoutsniper sniperescape village_defend ambush icbm
echo           launchfacility_a launchfacility_b jeepride airplane
set MAP=
set /p MAP="Mission to start [cargoship]: "
if "%MAP%"=="" set MAP=cargoship
set SQUAD=
set /p SQUAD="Squad size to wait for before the mission starts (1-4) [2]: "
if "%SQUAD%"=="" set SQUAD=2
echo.
echo Hosting "%MAP%" as %NAME%. The mission will hold on "Waiting for your squad" until %SQUAD% players are in.
start "" iw3sp.exe +set fs_game mods/coop +set loc_warnings 0 +set coop_host 1 +set coop_wait %SQUAD% +set coop_name "%NAME%" +set coop_startmap %MAP%

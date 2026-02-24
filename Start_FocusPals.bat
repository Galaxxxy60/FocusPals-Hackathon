@echo off
title FocusPals Launcher
echo ==============================
echo   FocusPals - Lancement...
echo ==============================
echo.
echo   L'agent Tama va lancer Godot
echo   automatiquement.
echo.
echo   Fermez cette fenetre pour
echo   tout arreter proprement.
echo ==============================
echo.

:: Force l'encodage UTF-8 pour éviter le crash des émojis en Python
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8

:: L'agent Python lance Godot + click-through + IA tout seul
python "%~dp0agent\tama_agent.py"

:: Quand l'agent s'arrete, on tue Godot
echo.
echo Arret de FocusPals...
taskkill /F /IM focuspals.exe >nul 2>&1
taskkill /F /IM focuspals.console.exe >nul 2>&1
echo Termine !
timeout /t 2 >nul

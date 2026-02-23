@echo off
title FocusPals Launcher
echo ==============================
echo   FocusPals - Lancement...
echo ==============================

:: Lance Tama 3D (Godot)
start "" "%~dp0godot\focuspals.exe"

:: Attend 2 secondes que la fenêtre apparaisse
timeout /t 2 /nobreak >nul

:: Applique le click-through Windows
python "%~dp0godot\click_through.py"

:: Lance l'agent IA
python "%~dp0agent\tama_agent.py"

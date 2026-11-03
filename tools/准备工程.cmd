@echo off
cd /d "%~dp0.."
py -3 tools\prepare_workspace.py
if errorlevel 1 python tools\prepare_workspace.py
pause

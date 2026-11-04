@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0KMReader-Kindle\KMReader-Kindle.exe" %*
if errorlevel 1 pause

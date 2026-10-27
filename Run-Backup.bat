@echo off
:: ── UEFA Board Application Backup Launcher ──────────────────────────────────
:: Double-click this file to run the backup script.
:: Sets the working directory to the folder containing this .bat file
:: and launches PowerShell with the correct execution policy.

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Backup-BoardApp.ps1"

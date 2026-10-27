@echo off
:: ── UEFA Board Application Backup Launcher (Debug / Logging Enabled) ────────
:: Double-click this file to run the backup script WITH full logging.
:: Use this when troubleshooting - transcript and AzCopy logs will be saved
:: to the logs/ folder.

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup-BoardApp.ps1" -EnableLogs

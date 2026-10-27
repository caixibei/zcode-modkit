@echo off
title ZCode Timezone Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-zcode-timezone.ps1"

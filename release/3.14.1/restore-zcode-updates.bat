@echo off
title ZCode Update Check Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-zcode-updates.ps1"

@echo off
title ZCode Usage Retention Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-zcode-usage.ps1"

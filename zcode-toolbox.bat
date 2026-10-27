@echo off
rem Session title tasks: [2]/[10] fix + refresh (integrated).
title ZCode Patch Toolbox
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zcode-toolbox.ps1" %*

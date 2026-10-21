@echo off
title ZCode Session Title Restore (Fix + Refresh)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-zcode-title-lastturn.ps1" %*

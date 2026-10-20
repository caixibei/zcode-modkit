@echo off
title ZCode Session Title Refresh Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-zcode-title-refresh.ps1" %*

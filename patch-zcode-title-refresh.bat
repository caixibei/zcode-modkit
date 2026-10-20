@echo off
title ZCode Session Title Refresh (Every N Turns)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch-zcode-title-refresh.ps1" %*

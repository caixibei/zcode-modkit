@echo off
title ZCode Session Title Patch (Fix + Refresh)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch-zcode-title-lastturn.ps1" %*

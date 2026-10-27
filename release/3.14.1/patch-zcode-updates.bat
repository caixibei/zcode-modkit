@echo off
title ZCode Update Check Disable
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch-zcode-updates.ps1"

@echo off
title ZCode Usage Retention Patch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch-zcode-usage.ps1"

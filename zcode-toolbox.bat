@echo off
rem Session title task [2]/[9] now uses the last-turn context patch.
title ZCode Patch Toolbox
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zcode-toolbox.ps1"

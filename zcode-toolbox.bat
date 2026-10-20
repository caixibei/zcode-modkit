@echo off
rem Session title tasks: [2]/[9] last-turn context, [15]/[16] refresh variant.
title ZCode Patch Toolbox
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zcode-toolbox.ps1"

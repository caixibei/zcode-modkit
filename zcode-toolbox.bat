@echo off
rem Session title tasks: [2]/[10] last-turn context, [8]/[16] refresh variant.
title ZCode Patch Toolbox
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zcode-toolbox.ps1"

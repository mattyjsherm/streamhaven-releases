@echo off
REM StreamHaven hub updater/launcher. Put this + update-streamhaven.ps1 on the hub
REM (e.g. C:\Hub\apps\) and run this at startup / before StreamHaven should open.
REM Any arguments are passed through, e.g.  update-streamhaven.cmd -NoLaunch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-streamhaven.ps1" %*
exit /b %ERRORLEVEL%

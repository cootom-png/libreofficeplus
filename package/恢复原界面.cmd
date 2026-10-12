@echo off
setlocal
pushd "%~dp0" || exit /b 1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\configure.ps1" -Restore %*
set "result=%errorlevel%"
popd
pause
exit /b %result%

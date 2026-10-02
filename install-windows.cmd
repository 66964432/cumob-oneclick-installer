@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "DEFAULT_INSTALLER_URL=https://github.com/66964432/cumob-oneclick-installer/archive/refs/heads/main.zip"

pushd "%SCRIPT_DIR%" >nul 2>&1
if errorlevel 1 (
  echo Unable to access the installer directory: %SCRIPT_DIR%
  echo Copy the installer to a local Windows folder and try again.
  pause
  exit /b 1
)
set "SCRIPT_DIR=%CD%\"

if exist "%SCRIPT_DIR%install.ps1" if exist "%SCRIPT_DIR%payload\cumob-models.json" goto install_local
goto install_remote

:install_local
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1" %*
set "INSTALL_EXIT=%ERRORLEVEL%"
goto finish

:install_remote
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$installerUrl = if ($env:CUMOB_INSTALLER_URL) { $env:CUMOB_INSTALLER_URL } else { '%DEFAULT_INSTALLER_URL%' };" ^
  "$workDir = Join-Path ([IO.Path]::GetTempPath()) ('cumob-bootstrap-' + [Guid]::NewGuid().ToString('N'));" ^
  "$archive = Join-Path $workDir 'installer.zip';" ^
  "$extractDir = Join-Path $workDir 'extracted';" ^
  "New-Item -ItemType Directory -Force -Path $extractDir | Out-Null;" ^
  "Write-Host ('Downloading latest installer from ' + $installerUrl);" ^
  "Invoke-WebRequest -Uri $installerUrl -OutFile $archive -UseBasicParsing;" ^
  "Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force;" ^
  "$root = Get-ChildItem -LiteralPath $extractDir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') -PathType Leaf } | Select-Object -First 1 -ExpandProperty FullName;" ^
  "if (-not $root) { throw 'Downloaded installer archive is invalid.' };" ^
  "& (Join-Path $root 'install.ps1') @args;" ^
  "Remove-Item -LiteralPath $workDir -Recurse -Force"
set "INSTALL_EXIT=%ERRORLEVEL%"

:finish
popd
echo.
if "%INSTALL_EXIT%"=="0" (
  echo Installation finished. Press any key to close this window.
) else (
  echo Installation failed with exit code %INSTALL_EXIT%. Press any key to close this window.
)
pause >nul
exit /b %INSTALL_EXIT%

@echo off
setlocal

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss_fff"') do set "TIMESTAMP=%%I"

set "ARCHIVE=project_%TIMESTAMP%.zip"
set "STAGING=%TEMP%\zipper_%TIMESTAMP%"

powershell -NoProfile -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$staging = '%STAGING%';" ^
  "New-Item -ItemType Directory -Path $staging -Force | Out-Null;" ^
  "try {" ^
  "  Copy-Item -Path '.\extensions', '.\scripts', '.\scenes', '.\AGENTS.md', '.\mainRun.tscn' -Destination $staging -Recurse -Force;" ^
  "  Get-ChildItem -Path $staging -Recurse -Directory -Filter 'bin' | Remove-Item -Recurse -Force;" ^
  "  Get-ChildItem -Path $staging -Recurse -File -Filter '*.dll' | Remove-Item -Force;" ^
  "  Compress-Archive -Path (Join-Path $staging '*') -DestinationPath '%ARCHIVE%' -CompressionLevel Optimal;" ^
  "} finally {" ^
  "  Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue;" ^
  "}"

if errorlevel 1 (
    echo.
    echo ERROR: Archive creation failed.
    exit /b 1
)

echo.
echo Created: %ARCHIVE%

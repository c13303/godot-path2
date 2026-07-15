@echo off
setlocal

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss_fff"') do set "TIMESTAMP=%%I"

set "ARCHIVE=project_%TIMESTAMP%.zip"

powershell -NoProfile -Command ^
  "Compress-Archive -Path '.\scripts', '.\scenes', '.\AGENTS.md', '.\mainRun.tscn' -DestinationPath '%ARCHIVE%' -CompressionLevel Optimal"

if errorlevel 1 (
    echo.
    echo ERROR: Archive creation failed.
    exit /b 1
)

echo.
echo Created: %ARCHIVE%
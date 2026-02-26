@echo off
setlocal

cd /d "%~dp0"

where Rscript >nul 2>nul
if errorlevel 1 (
  echo Error: Rscript not found in PATH.
  exit /b 1
)

echo [1/3] Running step1_get_data.R
Rscript step1_get_data.R
if errorlevel 1 exit /b %errorlevel%

echo [2/3] Running step2_sweep_grid_windows.R
Rscript step2_sweep_grid_windows.R
if errorlevel 1 exit /b %errorlevel%

echo [3/3] Running step3_build_3xportfolios_oos.R
Rscript step3_build_3xportfolios_oos.R
if errorlevel 1 exit /b %errorlevel%

echo Pipeline complete.
exit /b 0

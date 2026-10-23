@echo off
rem Copies Hermes's working folder to a folder of yours ("recuperer" = retrieve).
rem To run on the Windows test machine (the one of `lab remote add ... --windows`) with YOUR account (the one that sees C:\Users\hermes).
rem Never deletes anything: only copies (new and modified files).

set "SRC=C:\Users\hermes\work"
set "DST=%USERPROFILE%\Documents\hermes-work"

if not exist "%SRC%" (
  echo Source folder not found: %SRC%
  echo Hermes may not have written anything yet, or its profile does not exist.
  pause
  exit /b 1
)

if not exist "%DST%" mkdir "%DST%"

echo Copying %SRC%
echo      to %DST%
echo.
robocopy "%SRC%" "%DST%" /E /R:1 /W:1 /XJ /NP

rem robocopy returns 0 to 7 when everything went fine, 8 or more on error
if %ERRORLEVEL% GEQ 8 (
  echo.
  echo ERROR during the copy ^(code %ERRORLEVEL%^). Check that you run this file with your administrator account.
  pause
  exit /b %ERRORLEVEL%
)

echo.
echo Done. Files in: %DST%
start "" "%DST%"
pause

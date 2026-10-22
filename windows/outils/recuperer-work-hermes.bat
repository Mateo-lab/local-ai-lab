@echo off
rem Copie le dossier de travail de Hermes vers un dossier a toi.
rem A lancer sur la machine de test Windows (celle de `lab remote add ... --windows`) avec TON compte (celui qui voit C:\Users\hermes).
rem Ne supprime jamais rien : copie seulement (nouveaux fichiers et fichiers modifies).

set "SRC=C:\Users\hermes\work"
set "DST=%USERPROFILE%\Documents\hermes-work"

if not exist "%SRC%" (
  echo Dossier source introuvable : %SRC%
  echo Hermes n'a peut-etre encore rien depose, ou son profil n'existe pas.
  pause
  exit /b 1
)

if not exist "%DST%" mkdir "%DST%"

echo Copie de %SRC%
echo      vers %DST%
echo.
robocopy "%SRC%" "%DST%" /E /R:1 /W:1 /XJ /NP

rem robocopy renvoie 0 a 7 quand tout s'est bien passe, 8 ou plus en cas d'erreur
if %ERRORLEVEL% GEQ 8 (
  echo.
  echo ERREUR pendant la copie ^(code %ERRORLEVEL%^). Verifie que tu lances ce fichier avec ton compte administrateur.
  pause
  exit /b %ERRORLEVEL%
)

echo.
echo Termine. Fichiers dans : %DST%
start "" "%DST%"
pause

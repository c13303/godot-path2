@echo off
echo Copie en cours...

if not exist export mkdir export
cd C:\CHARLES\DEV\GODOTPROJS\FLOWFIELD_CPP\projet_godot\extensions\flowfield
:: Copier depuis chaque sous-dossier sauf export
for /d %%d in (*) do (
    if /i not "%%d"=="export" (
        xcopy "%%d\*.h" C:\CHARLES\DEV\GODOTPROJS\FLOWFIELD_CPP\projet_godot\export\ /S /Y /Q 2>nul
        xcopy "%%d\*.cpp" C:\CHARLES\DEV\GODOTPROJS\FLOWFIELD_CPP\projet_godot\export\ /S /Y /Q 2>nul
    )
)

:: Copier aussi depuis le dossier racine
copy *.h export\ 2>nul
copy *.cpp export\ 2>nul

echo Terminé!
pause
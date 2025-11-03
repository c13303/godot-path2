@echo off
cd /d "C:\Users\erreu\Documents\godot_path2"
git add -A
git commit -m "update"
if errorlevel 1 pause & exit /b
git push
if errorlevel 1 pause & exit /b
exit
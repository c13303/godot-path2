#!/bin/bash
set -e

cd /c/CHARLES/DEV/GODOTPROJS/FLOWFIELD_CPP/projet_godot
echo "=== Compilation ==="
scons -C extensions target=template_debug use_mingw=yes

echo "=== Lancement de Godot ==="
/c/CHARLES/DEV/GODOTPROJS/FLOWFIELD_CPP/godot451/Godot_v4.5.1-stable_win64.exe \
  --path "/c/CHARLES/DEV/GODOTPROJS/FLOWFIELD_CPP/projet_godot"

exec bash

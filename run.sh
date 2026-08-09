#!/bin/bash

cd /c/CHARLES/DEV/GODOTPROJS/RABBITGAME/dagodot-rabbitgame
echo "=== Compilation ==="
# Builds through the library's own SConstruct - the one a standalone copy of
# CPathLib ships - so the daily build and the packaged build are the same file.
if ! scons -C extensions/CPathLib target=template_debug use_mingw=yes \
    godot_cpp_dir=../../../godot-cpp; then
    echo "=== Compilation échouée ==="
    read -p "Appuyer pour quitter..."
    exit 1
fi

echo "=== Lancement de Godot ==="
/c/CHARLES/DEV/GODOTPROJS/RABBITGAME/engine/Godot_v4.5.1-stable_win64.exe \
  --path "/c/CHARLES/DEV/GODOTPROJS/RABBITGAME/dagodot-rabbitgame"

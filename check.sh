#!/bin/bash
#
# Builds CPathLib plus its unit tests, then runs every automated check:
#
#   * the two portable C++ unit tests (no engine involved);
#   * the three CPathLib smoke scripts, which exercise the library's own contracts;
#   * the four project smoke scripts, which exercise this game's use of it.
#
# The project smokes are the ones that matter for migration parity: the library
# can be correct while the project maps a value onto the wrong field, and that is
# exactly the class of bug the CPathLib smokes cannot see.
#
# Everything - build output and the full output of every failing check - is written
# to check.log, and the window is held open at the end. Send that file when a check
# fails; the console only shows the summary.
#
# Usage: ./check.sh                run everything
#        ./check.sh --skip-build   run the checks against the current binaries

set -u

PROJECT_DIR=/c/CHARLES/DEV/GODOTPROJS/RABBITGAME/dagodot-rabbitgame
GODOT=/c/CHARLES/DEV/GODOTPROJS/RABBITGAME/engine/Godot_v4.5.1-stable_win64.exe
GODOT_CPP_DIR=../../../godot-cpp
BIN="$PROJECT_DIR/extensions/CPathLib/bin"
LOG="$PROJECT_DIR/check.log"

cd "$PROJECT_DIR" || exit 1

failures=0
: > "$LOG"

say() {
    echo "$*"
    echo "$*" >> "$LOG"
}

hold() {
    echo
    echo "Full output: $LOG"
    read -r -p "Press enter to close..."
}

# Runs one check, keeping its output out of the console but in the log. On failure
# the last few lines are echoed too, so a glance at the window is already useful.
run_check() {
    local label="$1"
    shift
    local output status
    output="$("$@" 2>&1)"
    status=$?
    if [ "$status" -eq 0 ]; then
        say "  PASS  $label"
        return
    fi
    say "  FAIL  $label  (exit $status)"
    failures=$((failures + 1))
    {
        echo
        echo "===== FAIL: $label (exit $status) ====="
        echo "$output"
    } >> "$LOG"
    echo "$output" | tail -n 12 | sed 's/^/        /'
}

run_smoke() {
    run_check "$1" "$GODOT" --headless --path "$PROJECT_DIR" --script "$1"
}

if [ "${1:-}" != "--skip-build" ]; then
    say "=== Building library + tests ==="
    if ! scons -C extensions/CPathLib target=template_debug use_mingw=yes \
        godot_cpp_dir="$GODOT_CPP_DIR" tests >> "$LOG" 2>&1; then
        say "BUILD FAILED - see the log; nothing else was run."
        tail -n 40 "$LOG"
        hold
        exit 1
    fi
    say "build ok"
fi

say ""
say "=== C++ unit tests ==="
shopt -s nullglob
for executable in "$BIN"/test_*.exe; do
    run_check "$(basename "$executable")" "$executable"
done
shopt -u nullglob

# Each smoke script is its own SceneTree program: it exits 0 on success and 1 via
# _fail(). Run them one per process so one crash cannot mask the rest.
say ""
say "=== CPathLib smoke scripts ==="
run_smoke res://extensions/CPathLib/tests/navigation_world_2d_smoke.gd
run_smoke res://extensions/CPathLib/tests/crowd_world_2d_smoke.gd
run_smoke res://extensions/CPathLib/tests/projectile_world_2d_smoke.gd

say ""
say "=== Project boundary smoke scripts ==="
run_smoke res://scripts/native/native_runtime_boundary_smoke.gd
run_smoke res://scripts/native/game_runtime_adapter_smoke.gd
run_smoke res://scripts/native/game_player_collision_smoke.gd
run_smoke res://scripts/native/migration_parity_smoke.gd

say ""
if [ "$failures" -eq 0 ]; then
    say "=== all checks passed ==="
    hold
    exit 0
fi
say "=== $failures check(s) failed ==="
hold
exit 1

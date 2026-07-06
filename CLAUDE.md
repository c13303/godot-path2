# CLAUDE.md

Read this before editing code in this repository.

## Critical rules

- Do not run Godot, tests, compilation, export, or build commands.
- The user runs tests manually.
- Only run Godot if the user explicitly authorizes it in the current conversation.
- Godot executable, only if authorized: `C:\GAMETOOLS\godot`

## Architecture policy

Avoid creating huge source files.

Do not split files only to satisfy a line count.

Before adding substantial behavior to an existing file, check whether the file is still the correct owner.

If a planned change adds more than ~150 lines to one existing file, pause and explain:
- why the file is still the correct owner, or
- what new class/module/resource/node should own the behavior instead.

Files over ~800 lines are not automatically wrong, but they require caution.

Managers may coordinate systems, but should not accumulate unrelated gameplay logic.

## GDScript strict typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:
- numeric expressions
- Dictionary / Array values
- signal or `call()` returns
- mixed int / float math
- nullable or dynamic values

Prefer explicit local types:

```gdscript
var count: int = 0
var pos: Vector2i = Vector2i.ZERO
var speed: float = 0.0
var data: Dictionary = {}
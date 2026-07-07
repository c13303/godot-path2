# AGENTS.md

## General rule

For every task: do not guess. Ask if unsure.

## Test / build policy

Do not run Godot, tests, compilation, export, or build commands.

The user runs tests manually.

Only run Godot if the user explicitly authorizes it in the current conversation.

Godot executable, only if authorized:

```txt
C:\GAMETOOLS\godot
```

## GDScript typing

Godot/GDScript strict typing is enabled.

When editing GDScript, avoid `:=` inference for:

* numeric expressions
* Dictionary / Array values
* signal or `call()` returns
* mixed `int` / `float` math
* nullable or dynamic values

Prefer explicit local types.

Use explicit return types on new methods.

## Refactor policy

Do not split files only to reduce line count.

Prefer cohesive ownership over many tiny helper files.

Avoid creating or expanding files beyond approximately 1000 lines unless there is a clear reason.

If a file would exceed approximately 1000 lines, explain first:

* why the file is growing
* whether the code belongs in an existing subsystem
* whether a new subsystem is justified
* what public API the subsystem would expose

When extracting from a large manager file:

* move a clear responsibility, not random helper methods
* move related state with the behavior when practical
* avoid duplicate state between manager and service
* keep compatibility wrappers only when external callers may need them
* avoid hidden coupling through `_manager.call(...)`, `_manager.get(...)`, and `_manager.has_method(...)` when a clearer dependency is practical

## Scope control

Do not perform unrelated cleanup.

Do not optimize behavior unless explicitly asked.

Preserve existing behavior unless the task explicitly asks for a behavior change.

After each task, report:

* files changed
* behavior intentionally preserved
* compatibility wrappers kept, if any
* manual test risks

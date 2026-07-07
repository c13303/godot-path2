# AGENTS.md

## Core rule

Do not guess. Ask when requirements, ownership, or behavior are unclear.

For every coding task, watch file growth. Do not let files silently grow into large managers.

## Test / build policy

Do not run Godot, tests, compilation, export, or build commands.

The user runs tests manually.

Only run Godot if explicitly authorized in the current conversation.

Godot executable, only if authorized:

```txt
C:\GAMETOOLS\godot
```

## GDScript typing

Godot/GDScript strict typing is enabled.

Avoid `:=` inference for:

* numeric expressions
* Dictionary / Array values
* signal or `call()` returns
* mixed `int` / `float` math
* nullable or dynamic values

Prefer explicit local types:

```gdscript
var count: int = 0
var pos: Vector2i = Vector2i.ZERO
var speed: float = 0.0
var data: Dictionary = {}
```

Cast dynamic values before use:

```gdscript
var result: Variant = call(...)
var value: int = int(result)
```

## File size watch

Before editing an existing source file, check its line count.

Report the line count when the file is already large or central.

Use these thresholds:

```txt
0–500 lines: normal
500–800 lines: caution
800–1000 lines: high caution
1000+ lines: avoid adding more logic unless clearly justified
```

A file over 800 lines is not automatically wrong, but every new responsibility must be questioned.

A file over 1000 lines should usually stop growing. Prefer extracting new responsibilities instead of adding more logic to it.

Never create or expand a 1000+ line file by accident.

If a planned change would add more than ~150 lines to one file, pause before coding and explain the ownership choice.

If a file is already over ~800 lines, consider extraction before adding new behavior.

If a file is already over ~1000 lines, do not add substantial new logic unless there is a strong reason.

## Architecture rules

Do not implement new domain concepts by only expanding an existing manager.

Managers may coordinate systems, but should not accumulate unrelated gameplay logic.

A new responsibility should usually become one of:

* a new class
* a new node/component
* a new Resource
* a helper module with a narrow API

Split files for architectural reasons, not just to satisfy a number.

Good reasons to split:

* separate gameplay responsibility
* isolated state
* reusable subsystem
* clear public API
* logic that can be reasoned about independently
* manager accumulating unrelated behavior

Bad reasons to split:

* line count only
* tiny artificial files
* unclear ownership
* moving code without improving structure

Prefer coherent files over artificially tiny files.

## Before coding

Before writing code, identify:

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Current line count of touched files:
Estimated line additions per file:
Does this push any file over 800 or 1000 lines?
Should anything be split? Why / why not:
```

If ownership is unclear, propose the smallest safe architecture first.

## Cleanup and refactor

Cleanup is allowed when it directly supports the requested change.

Refactor when it:

* clarifies ownership
* reduces duplication
* extracts a real responsibility
* prevents a large file from growing further
* makes the requested change safer

Do not bundle unrelated cleanup with the task.

Do not mix unrelated feature work and unrelated fixes in one patch unless explicitly requested.

## Patch discipline

Keep patches small and scoped.

Preserve existing behavior unless a behavior change was requested.

Avoid unrelated rewrites, renames, formatting changes, or cleanup.

When touching large files, prefer delegation and extraction over adding more logic.

When extracting, keep the public behavior stable and make the existing file delegate to the new owner.

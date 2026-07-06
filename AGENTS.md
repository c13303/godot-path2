# AGENTS.md

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

## File size and architecture

Avoid creating huge source files.

Before editing a large or central source file, check its line count and consider whether the change belongs there.

A file over ~800 lines is not automatically wrong, but it requires caution.

Do not split files only to satisfy a line count.

Split only when there is a real architectural reason, such as:

* a separate gameplay responsibility
* a reusable subsystem
* isolated state
* a clear public API
* logic that can be tested or reasoned about independently
* a manager accumulating unrelated domain behavior

If a planned change would add more than ~150 lines to one existing file, pause before coding and explain whether:

* the file is still the correct owner
* the new logic should become a separate class/module/resource/node
* the existing file should only delegate to the new module

If a change would push a file far beyond ~800 lines, do not automatically split it. First justify whether keeping it together is cleaner than extracting a new responsibility.

## Responsibility rules

No class should own multiple unrelated gameplay responsibilities.

Do not implement a new domain concept by only expanding an existing manager.

A new domain concept should usually become one of:

* a new class
* a new node/component
* a new Resource
* a helper module with a narrow API

Managers may coordinate systems, but should not accumulate domain logic.

Prefer coherent files over artificially tiny files.

## Before coding

Before writing code, identify:

```txt
Owner:
Caller:
State owned:
Public API:
Files changed:
Estimated line additions per file:
Should anything be split? Why / why not:
```

If ownership is unclear, propose the smallest safe architecture first.

## Patch discipline

Keep patches small and scoped.

Preserve existing behavior unless a behavior change was requested.

Avoid unrelated rewrites, renames, formatting changes, or cleanup.

Do not mix refactor, new feature, cleanup, and unrelated fixes in one patch unless explicitly requested.

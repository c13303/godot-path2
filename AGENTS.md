do no run godot tests nor compilation
user do the tests

Godot/GDScript strict typing is enabled. When editing GDScript, avoid relying on := inference for numeric expressions, Dictionary values, signal/call returns, or mixed int/float math. Prefer explicit local types such as `var count: int = ...`, `var pos: Vector2i = ...`, and cast `call()` results before use.

No source file may exceed 800 lines without asking first.
No class may own more than one gameplay responsibility.
No new feature may be implemented by only expanding an existing manager if it introduces a new domain concept.
If a task would add more than 150 lines to one file, stop and propose a split.

Before coding, identify:
- which module owns the new behavior
- which existing file will call it
- what state it owns
- what public API it exposes
- what files will change
Do not implement until this is clear.



ONLY IF AUTHORISATION IS GIVEN BY USER : 
godot exe for tests : C:\GAMETOOLS\godot
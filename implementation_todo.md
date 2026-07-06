Task: reduce `scripts/map/building_manager.gd` by extracting agent definition / agent visual-data setup into a dedicated RefCounted service.

Context:
`BuildingManager` is still too large. Previous extractions have been tested. The next extraction should move agent definition lookup and visual/stat setup out of `BuildingManager`, while preserving behavior exactly.

Create a new file:

`scripts/map/agent_definition_service.gd`

with:

```gdscript
extends RefCounted
class_name AgentDefinitionService
```

Goal:
Move monster/client definition resolution and setup logic out of `BuildingManager`.

Extract these responsibilities from `BuildingManager` if they currently live there:

* monster scene resolution
* monster catalog lookup
* monster stat setup
* monster texture/sprite setup
* client texture/sprite setup
* fallback handling for unknown monster types

Likely methods to extract:

* `_resolve_monster_scene`
* `_apply_monster_data`

Also extract any small helper used only by those methods.

Do not extract spawning itself. `AgentSpawnController` should continue to own spawn orchestration.

Architecture:
Follow the existing RefCounted service/controller pattern.

The new service should keep a manager reference:

```gdscript
var _manager: Node

func setup(manager: Node) -> void:
	_manager = manager
```

Required public API:

```gdscript
func setup(manager: Node) -> void

func resolve_monster_scene(monster_type: StringName) -> PackedScene
func apply_monster_data(agent: Node, monster_type: StringName) -> void
func apply_client_data(agent: Node) -> void
```

If the current code has no separate client setup helper yet, create `apply_client_data(agent)` and move the client visual setup there from spawn orchestration.

Integration:

Add this member to `BuildingManager`:

```gdscript
var _agent_definition_service: AgentDefinitionService = AgentDefinitionService.new()
```

In `_ready()`:

```gdscript
_agent_definition_service.setup(self)
```

Replace the old methods in `BuildingManager` with thin wrappers:

```gdscript
func _resolve_monster_scene(monster_type: StringName) -> PackedScene:
	return _agent_definition_service.resolve_monster_scene(monster_type)

func _apply_monster_data(agent: Node, monster_type: StringName) -> void:
	_agent_definition_service.apply_monster_data(agent, monster_type)

func _apply_client_data(agent: Node) -> void:
	_agent_definition_service.apply_client_data(agent)
```

Then update `AgentSpawnController` to call:

```gdscript
_manager.call("_apply_client_data", agent)
```

instead of directly applying client sprite/hframes itself, if that logic currently lives in `AgentSpawnController`.

Keep compatibility wrappers in `BuildingManager` because other code may still use `_manager.call(...)`.

Constants and resources:
Move only constants/resources that are exclusively related to agent definitions or agent visual data.

Examples of things that may move if they are only used here:

* client texture preload
* monster scene fallback preload
* monster catalog dictionary
* default monster values
* sprite frame defaults

Do not move unrelated spawn constants.

Behavior preservation requirements:

1. Do not change monster type names.
2. Do not change fallback monster behavior.
3. Do not change default monster scene behavior.
4. Do not change texture paths.
5. Do not change sprite frame setup.
6. Do not change animation setup.
7. Do not change monster health/speed/damage/radius/stat values.
8. Do not change metadata keys.
9. Do not change group registration.
10. Do not change spawn routing.
11. Do not change desire registration.
12. Do not change native agent registration order.

Important ordering rule:
Monster data must still be applied before native agent registration, exactly as before.

The service should only apply data to an already-instantiated agent. It should not spawn, register, route, assign, or free agents.

Search all references before editing:

* `_resolve_monster_scene(`
* `_apply_monster_data(`
* `CLIENT_TEXTURE`
* monster catalog constants/dictionaries
* monster texture preloads
* client sprite setup
* `hframes`

Expected result:

* `building_manager.gd` loses another coherent block of data/setup code.
* `AgentSpawnController` becomes cleaner because it delegates agent-specific setup.
* `BuildingManager` keeps compatibility wrappers only.
* No `.tscn` changes required.
* No gameplay behavior changes.

Regression risks to avoid:

1. Do not accidentally apply monster data after `agent_manager.spawn_agent(...)`.
2. Do not move spawn failure cleanup into the definition service.
3. Do not make the definition service select gardens or routes.
4. Do not duplicate monster catalog state between `BuildingManager` and the service.
5. Do not change resource preload paths.
6. Do not change unknown monster fallback behavior.
7. Do not change client group/desire registration.
8. Do not rename concepts.
9. Do not compile or run tests; I will do it.

Non-goals:
Do not extract spawn orchestration again.
Do not modify pathfinding.
Do not modify garden routing.
Do not modify playlist logic.
Do not modify build placement/removal.
Do not perform unrelated cleanup.

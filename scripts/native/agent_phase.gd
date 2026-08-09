extends RefCounted

## Mission phase codes, shared between FlowAgent (which sets them) and
## AgentDebugLabelController (which renders them).
##
## Consumed with `const AgentPhase = preload(...)`, deliberately not `class_name`.
## A global class name only exists once the editor has imported the file, so a fresh
## clone - or any run before that import - would fail to parse every dependent
## script. A preload path is resolved directly and always works.
##
## Deliberately dependency-free. The label controller used to read these from
## FlowAgent, which pulled character.gd -> agent_definition_service.gd ->
## building_manager.gd -> the GameState autoload. Autoloads do not exist under
## `godot --headless --script`, so that chain broke every headless smoke run that
## touched CrowdRuntime. Nothing may be added here that imports another script.
##
## Values must match ffcore::AgentPhase ordering in the pre-migration native code.
const NONE: int = 0
const FLOW_IN: int = 1
const ASTAR_IN: int = 2
const EATING: int = 3
const ASTAR_OUT: int = 4
const FLOW_OUT: int = 5
const WAITING_NEW_STATUS: int = 6
const DROWNING: int = 7

class_name LevelLoader
extends Node

## Loads the authored map for a run before the game starts. A "level" is the three
## authored TileMapLayers (floor / watersources / wallz); every level_*.tscn is a
## self-contained, human-designed map that can be swapped here without touching
## mainRun.
##
## This node is placed as the FIRST child of the root game node. During scene
## instantiation _enter_tree runs top-down, so when this fires the MonTilemap host
## has not entered the tree yet — it is neither "inside tree" nor busy setting up
## children, so add_child() on it is allowed (adding to a node that is mid-init,
## e.g. our own parent, is what Godot forbids). The injected layers then enter and
## become ready in normal propagation order, so by the time any gameplay system
## resolves Map/MonTilemap/floor (etc.) in _ready, the layers already exist —
## loading a level never changes how the rest of the game runs.

## Host that receives the level's layers, relative to this node (root's child).
@export var montilemap_path: NodePath = ^"../Map/MonTilemap"
## The level to load before the game starts. Assigned in mainRun.tscn.
@export var level_scene: PackedScene

## The authored layers a level provides, in the order they should be hosted.
const LEVEL_LAYER_NAMES: PackedStringArray = ["floor", "watersources", "wallz"]

var _loaded_level_scene_path: String = ""

func _enter_tree() -> void:
	_load_level()

func _load_level() -> void:
	var scene_to_load: PackedScene = _resolve_level_scene()
	if scene_to_load == null:
		push_error("LevelLoader: no level_scene assigned; map layers will be missing.")
		return

	var host: Node = get_node_or_null(montilemap_path)
	if host == null:
		push_error("LevelLoader: MonTilemap host not found at '%s'." % montilemap_path)
		return

	# Instanced off-tree; we only keep its authored layers and discard the shell.
	var level_root: Node = scene_to_load.instantiate()
	for layer_name in LEVEL_LAYER_NAMES:
		var layer: Node = level_root.get_node_or_null(NodePath(layer_name))
		if layer == null:
			push_warning("LevelLoader: level '%s' is missing layer '%s'." % [scene_to_load.resource_path, layer_name])
			continue
		if host.has_node(NodePath(layer_name)):
			push_warning("LevelLoader: host already has a '%s' layer; skipping." % layer_name)
			continue
		level_root.remove_child(layer)
		layer.name = layer_name
		host.add_child(layer)

	level_root.free()
	_loaded_level_scene_path = scene_to_load.resource_path


func get_loaded_level_scene_path() -> String:
	return _loaded_level_scene_path


func _resolve_level_scene() -> PackedScene:
	var selected_path: String = GameState.get_selected_level_scene_path()
	if selected_path != "":
		var selected_resource: Resource = load(selected_path)
		var selected_scene: PackedScene = selected_resource as PackedScene
		if selected_scene != null:
			return selected_scene
		push_warning("LevelLoader: selected level '%s' could not be loaded; using exported level." % selected_path)
	return level_scene

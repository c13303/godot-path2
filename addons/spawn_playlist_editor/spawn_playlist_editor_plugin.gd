@tool
extends EditorPlugin

const SpawnPlaylistEditorDock: Script = preload("res://addons/spawn_playlist_editor/spawn_playlist_editor_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = SpawnPlaylistEditorDock.new() as Control
	_dock.name = "Rose Level Editor"
	_dock.custom_minimum_size = Vector2(560.0, 420.0)
	_dock.set("editor_plugin", self)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

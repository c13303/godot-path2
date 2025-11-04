extends Node


# -----------------------------------------------------
# Conversion entre coordonnées cellule et monde
# -----------------------------------------------------

# Retourne la position monde du centre d'une cellule
# Compatible TileMap et TileMapLayer
static func get_tile_pos_from_cell(tilemap: Object, cell: Vector2i) -> Vector2:
	if tilemap == null:
		return Vector2.ZERO

	# Godot 4.4 : TileMap.map_to_local renvoie le centre local
	if tilemap is TileMap:
		var local_pos: Vector2 = tilemap.map_to_local(cell)
		return tilemap.to_global(local_pos)
	elif tilemap is TileMapLayer:
		var local_pos_layer: Vector2 = tilemap.map_to_local(cell)
		return tilemap.to_global(local_pos_layer)
	else:
		push_warning("Utils.get_tile_pos_from_cell: objet incompatible")
		return Vector2.ZERO


# -----------------------------------------------------
# Conversion entre position monde et cellule
# -----------------------------------------------------

# Renvoie la cellule correspondante à une position monde
static func world_to_cell(tilemap: Object, world_pos: Vector2) -> Vector2i:
	if tilemap == null:
		return Vector2i.ZERO

	if tilemap is TileMap:
		var local: Vector2 = tilemap.to_local(world_pos)
		return tilemap.local_to_map(local)
	elif tilemap is TileMapLayer:
		var local_layer: Vector2 = tilemap.to_local(world_pos)
		return tilemap.local_to_map(local_layer)
	else:
		push_warning("Utils.world_to_cell: objet incompatible")
		return Vector2i.ZERO


# -----------------------------------------------------
# Conversion directe depuis la souris
# -----------------------------------------------------

# Retourne la position monde centrée sur la cellule sous la souris
# Nécessite un TileMap passé en argument (floor_layer ou équivalent)
static func get_tile_pos_from_mouse(tilemap: Object) -> Vector2:
	if tilemap == null:
		return Vector2.ZERO

	var viewport: Viewport = tilemap.get_viewport()
	if viewport == null:
		return Vector2.ZERO

	var mouse_world: Vector2 = viewport.get_mouse_position()
	if tilemap.has_method("get_global_mouse_position"):
		mouse_world = tilemap.get_global_mouse_position()

	var cell: Vector2i = world_to_cell(tilemap, mouse_world)
	return get_tile_pos_from_cell(tilemap, cell)

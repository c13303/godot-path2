extends RefCounted

## Resolves and presents the resource consumed by a successful placement.
## Placement remains responsible for deciding when a commit succeeded.


static func capture(game_ui: CanvasLayer, item_id: String, count: int) -> Dictionary:
	if game_ui == null or item_id == "" or count <= 0:
		return {}
	if ItemCatalog.is_inventory_backed(item_id):
		return {"item_id": item_id, "amount": count}
	var currency: StringName = ItemCatalog.get_currency(item_id)
	if currency == &"" or not CurrencyCatalog.has_currency(currency):
		return {}
	if not game_ui.has_method("get_build_price_total_for_next"):
		return {}
	var amount: int = int(game_ui.call("get_build_price_total_for_next", item_id, count))
	if amount <= 0:
		return {}
	return {"item_id": CurrencyCatalog.get_item_id(currency), "amount": amount}


static func play_at_cell(
	game_ui: CanvasLayer,
	visual_data: Dictionary,
	cell: Vector2i,
	coordinate_layer: TileMapLayer
) -> void:
	var cells: Array[Vector2i] = [cell]
	play_at_cells(game_ui, visual_data, cells, coordinate_layer)


static func play_at_cells(
	game_ui: CanvasLayer,
	visual_data: Dictionary,
	cells: Array[Vector2i],
	coordinate_layer: TileMapLayer
) -> void:
	if (
		game_ui == null
		or coordinate_layer == null
		or cells.is_empty()
		or not game_ui.has_method("play_item_from_player_to_world")
	):
		return
	var visual_item_id: String = str(visual_data.get("item_id", ""))
	var total_amount: int = maxi(0, int(visual_data.get("amount", 0)))
	if visual_item_id == "" or total_amount <= 0:
		return
	@warning_ignore("integer_division")
	var amount_per_cell: int = total_amount / cells.size()
	var remainder: int = total_amount % cells.size()
	for index: int in range(cells.size()):
		var cell_amount: int = amount_per_cell + (1 if index < remainder else 0)
		if cell_amount <= 0:
			continue
		var world_position: Vector2 = coordinate_layer.to_global(coordinate_layer.map_to_local(cells[index]))
		game_ui.call("play_item_from_player_to_world", visual_item_id, world_position, cell_amount)


static func scaled(visual_data: Dictionary, placed_count: int, requested_count: int) -> Dictionary:
	if visual_data.is_empty() or placed_count <= 0 or requested_count <= 0:
		return {}
	var result: Dictionary = visual_data.duplicate()
	var requested_amount: int = maxi(0, int(visual_data.get("amount", 0)))
	result["amount"] = int(round(float(requested_amount) * float(placed_count) / float(requested_count)))
	return result

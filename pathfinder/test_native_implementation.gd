extends Node

func _ready():
	var n = $"../SteeringSystemNative"
	var g = $"../SpatialGridNative"

	print("Class:", n.get_class())
	print("Has method update_all_agents:", n.has_method("update_all_agents"))

	if n and n.has_method("update_all_agents"):
		n.update_all_agents(0.016)
	else:
		print("SteeringSystemNative introuvable ou méthode absente")

	if g and g.has_method("get_neighbors"):
		print("SpatialGridNative ok")
	else:
		print("SpatialGridNative introuvable ou méthode absente")

	n.set_grid(g)
	print("Grille assignée avec succès.")



func _process(_delta):
	var n = $"../SteeringSystemNative"
	var g = $"../SpatialGridNative"

	if not n or not g:
		return

	var agents = get_tree().get_nodes_in_group("main_chars")
	if agents.size() > 0:
		var first = agents[0]
		#print("Neighbors:", g.get_neighbors(first.global_position, 1))
		set_process(false) # on stoppe après un check

extends Node

func _ready():
	var n = $"../SteeringSystemNative"
	print("Class:", n.get_class())
	print("Has method update_all_agents:", n.has_method("update_all_agents"))
	
	if n and n.has_method("update_all_agents"):
		n.update_all_agents(0.016)
	else:
		print("SteeringSystemNative introuvable ou méthode absente")

extends Resource
class_name KrakenData

@export_range(16.0, 512.0, 1.0, "or_greater") var capture_range: float = 254.0
@export_range(0.02, 2.0, 0.01) var target_scan_interval: float = 0.1
@export_range(0.1, 30.0, 0.1) var digestion_seconds: float = 5.0
@export var forced_drop_currency: StringName = &"gem"

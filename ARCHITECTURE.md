# Map / Building architecture

## BuildingManager
Role: high-level orchestrator and compatibility facade.
Should not own detailed garden/path/spawner/placement logic long-term.

## GardenTopologyService
Owns garden/plant cluster topology.

## GardenRetargetController
Owns retargeting agents after plant removal or garden invalidation.

## AgentNavigationPhaseController
Owns monster phase transitions:
spawn -> flow in -> eat -> flow out -> exit.

## SpawnerRouteService
Owns spawner-to-target route selection and cached route state.

## BuildPlacementService
Owns validation and placement side effects.

## BuildDragController
Owns drag build/remove state.

## BuildPreviewController
Owns preview visuals only.
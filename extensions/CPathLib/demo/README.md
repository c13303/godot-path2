# Minimal reusable navigation demo

Open `navigation_demo.tscn` in any scene or run it as the main scene. It creates only the two generic
extension nodes at runtime: `NavigationWorld2D` and `CrowdWorld2D`.

The demo uploads a raw grid, builds a shared flow, defines an area and portal, verifies a typed area
route, moves two generic agents through a capacity-one bottleneck, and applies an impulse. It does
does not require host scenes, autoloads, TileMaps, scripts, groups, or resources.

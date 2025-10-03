extends Node
class_name BoidsBuilder

# MAIN BUILD FUNCTION
func build_random_boids(owner_node) -> Dictionary:
	var pos := []
	var vel := []
	
	var zone_size = owner_node.image_size * owner_node.zone_size_mult
	for i in range(owner_node.boids_count):
		# Random position inside zone
		var x = randf_range(-zone_size * 0.5, zone_size * 0.5)
		var y = randf_range(-zone_size * 0.5, zone_size * 0.5)
		pos.append(Vector2(x, y))

		# No velocity
		vel.append(Vector2.ZERO)

	return {
		"pos": pos,
		"vel": vel
	}

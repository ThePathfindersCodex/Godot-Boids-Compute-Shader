extends Node2D

var slider_bindings = {
	"%SliderSpeed": "dt",
	"%SliderVisionRadius": "vision_radius",
	"%SliderAlignmentForce": "alignment_force",
	"%SliderCohesionForce": "cohesion_force",
	"%SliderSeparationForce": "separation_force",
	"%SliderSteeringForce": "steering_force",
	"%SliderMinSpeed": "min_speed",
	"%SliderMaxSpeed": "max_speed",
	"%SliderDrag": "drag",
	"%SliderMovementRandomness": "movement_randomness",
	"%SliderMovementAccuracy": "movement_accuracy",
	"%SliderDrawRadius": "draw_radius"
}

func _ready():
	# Connect all sliders and set defaults
	for slider_path in slider_bindings.keys():
		var slider = get_node(slider_path)
		var property = slider_bindings[slider_path]
		slider.value = %ComputeBoids.get(property)
		slider.connect("value_changed", Callable(self, "_on_slider_changed").bind(property))
	
	# Options default values
	%OptionStartPointCount.selected = 3
#
func _process(_delta):
	# SET READOUT VALUES
	%LabelPointsValue.text = str(snapped(%ComputeBoids.boids_count,1))
	%LabelSpeedValue.text = str(snapped(%ComputeBoids.dt,.01))
	%LabelVisionRadiusValue.text = str(snapped(%ComputeBoids.vision_radius,1))
	%LabelAlignmentForceValue.text = str(snapped(%ComputeBoids.alignment_force,.1))
	%LabelCohesionForceValue.text = str(snapped(%ComputeBoids.cohesion_force,.1))
	%LabelSeparationForceValue.text = str(snapped(%ComputeBoids.separation_force,.1))
	%LabelSteeringForceValue.text = str(snapped(%ComputeBoids.steering_force,.1))
	%LabelMinSpeedValue.text = str(snapped(%ComputeBoids.min_speed,.1))
	%LabelMaxSpeedValue.text = str(snapped(%ComputeBoids.max_speed,.1))
	%LabelDragValue.text = str(snapped(%ComputeBoids.drag,.01))
	%LabelSliderMovementRandomnessValue.text = str(snapped(%ComputeBoids.movement_randomness,.1))
	%LabelSliderMovementAccuracyValue.text = str(snapped(%ComputeBoids.movement_accuracy,.1))
	%LabelDrawRadiusValue.text = str(snapped(%ComputeBoids.draw_radius,1))
	
	%LabelCamCenterValue.text = "("+str(snapped(%ComputeBoids.camera_center.x,.1))+ ", " + str(snapped(%ComputeBoids.camera_center.y,.1)) + ")"
	%LabelZoomValue.text = str(snapped(%ComputeBoids.zoom,.01))

	# HANDLE PAUSE/RESUME
	if Input.is_action_just_pressed("pause_resume"):
		pause_resume()

func pause_resume():
	if %ComputeBoids.dt == 0.0:
		%ComputeBoids.dt = %ComputeBoids.paused_dt  # resume
		%ButtonPauseResume.text = "PAUSE"
	else:
		%ComputeBoids.paused_dt = %ComputeBoids.dt  # store current
		%ComputeBoids.dt = 0.0       # pause
		%ButtonPauseResume.text = "RESUME"

func _on_slider_changed(value: float, property: String):
	%ComputeBoids.set(property, value)

func _on_button_restart_pressed() -> void:
	%ComputeBoids.restart_simulation()

func _on_button_pause_resume_pressed() -> void:
	pause_resume()

func _on_option_start_point_count_item_selected(index: int) -> void:
	%ComputeBoids.start_boids_count=int(%OptionStartPointCount.get_item_text(index))

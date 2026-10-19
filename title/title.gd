extends Control
## The title screen, to play or to exit the game. What's selected lights up,
## with a fireball next to it, whether it's selected with the mouse or the
## arrow keys.

var _time := 0.0
var _ghost_homes := []


func _ready() -> void:
	_ghost_homes = $Ghosts.get_children().map(func(ghost): return ghost.position)

	$Menu/Play.grab_focus()
	for button: Button in $Menu.get_children():
		# The mouse selects what it's over, like the arrow keys do.
		button.mouse_entered.connect(button.grab_focus)
		button.focus_entered.connect($Select.play)
	$Menu/Play.pressed.connect(_play)
	$Menu/Exit.pressed.connect(get_tree().quit)


func _process(delta: float) -> void:
	_time += delta

	# The fireball slides over to what's selected.
	var selected := get_viewport().gui_get_focus_owner()
	if selected:
		var goal: Vector2 = selected.position + $Menu.position + Vector2(-10, selected.size.y / 2)
		$Marker.position = $Marker.position.lerp(goal, 1.0 - exp(-20.0 * delta))

	# Pipecat breathes, and the ghosts float around it.
	$Cat.scale.y = 4.0 * (1.0 + 0.03 * sin(_time * 2.0))
	for i in _ghost_homes.size():
		var ghost: Sprite2D = $Ghosts.get_child(i)
		var wander := Vector2(sin(_time * 0.5 + i * 2.0) * 16.0, cos(_time * 0.7 + i) * 8.0)
		ghost.position = _ghost_homes[i] + wander
		ghost.flip_h = cos(_time * 0.5 + i * 2.0) < 0


func _play() -> void:
	$Start.play()
	var tween := create_tween()
	tween.tween_property($Fade, "color:a", 1.0, 0.6)
	await tween.finished
	get_tree().change_scene_to_file("res://village/village.tscn")

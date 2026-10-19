class_name Fireball
extends Node2D
## A fireball, which flies at a ghost, and bursts when it gets there.

## How fast fireballs fly, in pixels per second.
const SPEED := 150.0

## The ghost it flies at.
var target: Ghost


func _process(delta: float) -> void:
	# The ghost can vanish first, e.g. if it scares the player.
	if not is_instance_valid(target) or not target.is_in_group("ghosts"):
		_burst()
		return
	var to_target := target.global_position - global_position
	if to_target.length() < 6.0 * target.scale.x:
		target.incoming -= 1
		target.hit()
		_burst()
		return
	global_position += to_target.normalized() * SPEED * delta


func _burst() -> void:
	set_process(false)
	$Sprite.hide()
	$Trail.emitting = false
	$Burst.emitting = true
	$Sound.play()
	create_tween().tween_property($Light, "energy", 0.0, 0.4).from(2.5)

	# Shakes the screen a little.
	var camera := get_viewport().get_camera_2d()
	var shake := camera.create_tween()
	for i in 3:
		shake.tween_property(camera, "offset", Vector2(randf_range(-2, 2), randf_range(-2, 2)), 0.04)
	shake.tween_property(camera, "offset", Vector2.ZERO, 0.04)

	await $Sound.finished
	queue_free()

class_name Ghost
extends Node2D
## A ghost, which floats toward the player to scare them, unless fireballs or
## the sword get it first. Big ghosts are slower, and take two hits.

## Tiny Dungeon's ghosts.
const FRAMES := [121, 108]
## How close ghosts get to each other, in pixels.
const APART := 14.0
## How big big ghosts are.
const BIG := 1.5

## Who the ghost floats toward.
var target: Player
## Whether it's a big one.
var big := false
## How many more hits it takes.
var hits := 1
## How many fireballs are on their way to it.
var incoming := 0

var _time := randf() * TAU
# Some ghosts are faster than others, in pixels per second.
var _speed := randf_range(12.0, 20.0)


func _ready() -> void:
	$Sprite.frame = FRAMES.pick_random()
	if big:
		scale = Vector2.ONE * BIG
		hits = 2
		_speed *= 0.7
	# Fades in.
	$Sprite.modulate.a = 0.0
	create_tween().tween_property($Sprite, "modulate:a", 0.85, 1.0)


func _process(delta: float) -> void:
	_time += delta
	# Floats toward its target, wobbling, and keeping away from other ghosts.
	var direction := global_position.direction_to(target.global_position)
	var motion := direction * _speed + Vector2(0, sin(_time * 2.0) * 6.0)
	for other: Ghost in get_tree().get_nodes_in_group("ghosts"):
		var away := global_position - other.global_position
		if other != self and away.length() < APART * scale.x:
			motion += away.normalized() * _speed
	global_position += motion * delta
	$Sprite.flip_h = direction.x < 0
	if global_position.distance_to(target.global_position) < 8.0 * scale.x:
		target.scare()
		vanish()


## Takes a hit, from a fireball or the sword. Returns whether it vanished.
func hit() -> bool:
	hits -= 1
	if hits <= 0:
		vanish()
		return true
	# Flashes, and shrinks a bit.
	var tween := create_tween().set_parallel()
	tween.tween_property($Sprite, "modulate", Color(1, 1, 1, 0.85), 0.3).from(Color(3, 3, 3))
	tween.tween_property(self, "scale", Vector2.ONE * 1.2, 0.3)
	return false


## Disappears in a puff.
func vanish() -> void:
	remove_from_group("ghosts")
	set_process(false)
	$Poof.emitting = true
	$Sound.play()
	var tween := create_tween().set_parallel()
	tween.tween_property($Sprite, "modulate:a", 0.0, 0.3)
	tween.tween_property($Light, "energy", 0.0, 0.3)
	await $Sound.finished
	queue_free()

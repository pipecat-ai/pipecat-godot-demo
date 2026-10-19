class_name Cat
extends Node2D
## Pipecat, a little black cat with magic powers. It walks around the player,
## playfully, unless it's somewhere else, finding its way around what's in the
## village, and glows as it speaks. When it's told to fight, it throws fireballs at the
## ghosts it was told to fight, until they're gone.

## Pipecat got where it was walking to.
signal arrived

const FIREBALL := preload("res://village/fireball.tscn")

## How fast Pipecat walks, in pixels per second: as fast as the player, unless
## it gets out of their way.
const SPEED := Player.SPEED
const SCURRY := 1.5
## How far Pipecat stays from who it follows, without bumping into them, in
## pixels.
const APART := 20.0
## Now and then, while who it follows stands still, Pipecat moves around them a
## little, playfully: every so many seconds, and up to so far around them, in
## radians.
const PLAY_TIME := Vector2(2.0, 5.0)
const PLAY_TURN := PI / 3
## How long Pipecat takes to throw another fireball, in seconds.
const THROW_TIME := 0.8
## How far Pipecat's fireballs reach, in pixels.
const RANGE := 120.0

## The village's tiles, with what Pipecat can't walk through, to find its way.
var grid: AStarGrid2D
## How loud Pipecat's voice is, from 0 to 1.
var voice_level := 0.0
## What Pipecat carries, if anything.
var carrying: Node2D
## The ghosts Pipecat throws fireballs at, until they're gone.
var targets := []

var _following: Node2D
# Where Pipecat goes around who it follows, as an angle: 0 is on their right.
var _around := 0.0
var _play_in := 0.0
var _last_seen := Vector2.ZERO
var _path := PackedVector2Array()
var _steps := 0.0
var _glow := 0.0
var _next_throw := 0.0


## Follows `node` around, starting on the side Pipecat is on.
func follow(node: Node2D) -> void:
	_following = node
	_around = node.global_position.angle_to_point(global_position)


## Where Pipecat goes to be next to `node`, without bumping into them: on a
## square around them, as they're both square.
func beside(node: Node2D) -> Vector2:
	var direction := Vector2.from_angle(_around)
	return node.global_position + direction / maxf(absf(direction.x), absf(direction.y)) * APART


## Walks over to `where`, or as close as it gets, and stays there.
func walk_to(where: Vector2) -> void:
	_following = null
	_walk(where)
	if _path:
		await arrived


func carry(item: Node2D) -> void:
	carrying = item
	item.reparent(self, false)


func drop() -> Node2D:
	var item := carrying
	carrying = null
	return item


func _process(delta: float) -> void:
	# Walks after who it follows, staying beside them. Now and then, while they
	# stand still, it moves around them a little, and somewhere else if there's
	# no room. On the last stretch, it keeps up with them as they move, unless
	# it has to go around.
	if _following:
		if _following.global_position.is_equal_approx(_last_seen):
			_play_in -= delta
		_last_seen = _following.global_position
		if _play_in <= 0.0:
			_play_in = randf_range(PLAY_TIME.x, PLAY_TIME.y)
			_around += randf_range(-PLAY_TURN, PLAY_TURN)
		if not _has_room(beside(_following)):
			_around = _following.global_position.angle_to_point(global_position)
		for i in 4:
			if _has_room(beside(_following)):
				break
			_around += PI / 2
		var goal := beside(_following)
		if _path.size() == 1 and _path[0].distance_to(goal) < 8.0:
			_path[0] = goal
		elif not _path and global_position.distance_to(goal) > 2.0:
			_walk(goal)

	if _path:
		var next := _path[0]
		if absf(next.x - global_position.x) > 1.0:
			$Sprite.flip_h = next.x < global_position.x
		var speed := SPEED
		if _following and global_position.distance_to(_following.global_position) < APART:
			speed *= SCURRY
		global_position = global_position.move_toward(next, speed * delta)
		if global_position.is_equal_approx(next):
			_path.remove_at(0)
			if not _path:
				arrived.emit()

	# Forgets the targets that are gone.
	targets = targets.filter(
		func(ghost): return is_instance_valid(ghost) and ghost.is_in_group("ghosts")
	)
	_next_throw -= delta
	if targets and _next_throw <= 0.0:
		_throw_fireball()

	# Hops a little as it walks, and grows and glows as it speaks.
	_steps = _steps + delta if _path else 0.0
	$Sprite.position.y = -absf(sin(_steps * 10.0)) * 1.5
	_glow = lerpf(_glow, voice_level, 1.0 - exp(-14.0 * delta))
	$Sprite.scale = Vector2.ONE * (1.0 + 0.2 * _glow)
	$Light.energy = 0.7 + 1.3 * _glow
	# Carries things in its mouth.
	if carrying:
		carrying.position = Vector2(-6 if $Sprite.flip_h else 6, 3)


func _has_room(where: Vector2) -> bool:
	var tile := Vector2i(where / grid.cell_size)
	return grid.is_in_boundsv(tile) and not grid.is_point_solid(tile)


## Finds the way to `where`, tile by tile, around what's in the way. If it can't
## get there, e.g. into the well, it gets as close as it can.
func _walk(where: Vector2) -> void:
	var from := Vector2i(global_position / grid.cell_size)
	var to := Vector2i(where / grid.cell_size)
	# It goes around who it follows, rather than over them.
	var around := Vector2i(_following.global_position / grid.cell_size) if _following else from
	var solid := grid.is_point_solid(around)
	if around != from and around != to:
		grid.set_point_solid(around)
	_path = grid.get_point_path(from, to, true)
	grid.set_point_solid(around, solid)
	# It ends right where it's going, if it gets there.
	if _path and _path[-1] == grid.get_point_position(to):
		_path[-1] = where
	# It's already on the first tile.
	if _path.size() > 1:
		_path.remove_at(0)


## Throws a fireball at the nearest target in range that doesn't have enough
## coming already. The others need to get closer first.
func _throw_fireball() -> void:
	var target: Ghost
	var nearest := RANGE
	for ghost: Ghost in targets:
		var distance := global_position.distance_to(ghost.global_position)
		if ghost.incoming < ghost.hits and distance < nearest:
			target = ghost
			nearest = distance
	if not target:
		return
	target.incoming += 1
	var fireball: Fireball = FIREBALL.instantiate()
	fireball.target = target
	fireball.position = position
	add_sibling(fireball)
	$ThrowSound.play()
	_next_throw = THROW_TIME
	# Glows as it throws.
	_glow = maxf(_glow, 0.6)

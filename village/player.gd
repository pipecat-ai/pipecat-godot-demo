class_name Player
extends CharacterBody2D
## The player, who walks with the arrow keys or WASD, and glows as they speak.
## Once they have the sword, they hold it, and swing it with Space.

## A ghost scared the player, who has half a heart less.
signal scared
## The player got some ghosts with their sword.
signal struck(ghosts: int)

const SPEED := 70.0
const MAX_HEARTS := 3
## How far the sword reaches, in pixels.
const SWORD_REACH := 22.0
## How the player holds the sword, and swings it, as angles from upright.
const SWORD_HELD := 0.4
const SWORD_SWING := Vector2(-1.2, 1.9)

## How loud the player is, from 0 to 1.
var voice_level := 0.0
## The player's hearts, by halves, shown at the top of the screen.
var hearts := float(MAX_HEARTS):
	set(value):
		hearts = value
		for i in hearts_display.get_child_count():
			# Full, half, or empty.
			hearts_display.get_child(i).frame = 0 if hearts >= i + 1 else (1 if hearts > i else 2)

## Where what Pipecat gives the player goes, at the top of the screen.
@export var inventory: Node2D
@export var hearts_display: Node2D

var _glow := 0.0
var _swinging := false


func _ready() -> void:
	inventory.child_order_changed.connect(_on_inventory_changed)


func has_item(item_name: String) -> bool:
	return inventory.has_node(item_name)


func take(item: Node2D) -> void:
	item.reparent(inventory, false)


## An item the player has, to give to someone else, who takes it.
func give(item_name: String) -> Node2D:
	return inventory.get_node_or_null(item_name)


func scare() -> void:
	hearts -= 0.5
	$ScaredSound.play()
	# Flashes, startled.
	create_tween().tween_property($Sprite, "modulate", Color.WHITE, 0.4).from(Color(3, 3, 3))
	scared.emit()


func _on_inventory_changed() -> void:
	for i in inventory.get_child_count():
		inventory.get_child(i).position = Vector2(12 + 18 * i, 12)
	$Sword.visible = has_item("sword")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("swing") and has_item("sword"):
		_swing()


## Swings the sword, which gets the ghosts nearby.
func _swing() -> void:
	var side := _side()
	_swinging = true
	$SwingSound.play()
	var tween := create_tween()
	tween.tween_property($Sword, "rotation", SWORD_SWING.y * side, 0.15).from(SWORD_SWING.x * side)
	tween.tween_callback(func(): _swinging = false)

	var ghosts := 0
	for ghost: Ghost in get_tree().get_nodes_in_group("ghosts"):
		if global_position.distance_to(ghost.global_position) < SWORD_REACH and ghost.hit():
			ghosts += 1
	if ghosts:
		struck.emit(ghosts)


func _physics_process(delta: float) -> void:
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * SPEED
	move_and_slide()
	if direction.x:
		$Sprite.flip_h = direction.x < 0
	# Holds the sword, a short one, on the side they face.
	if not _swinging:
		$Sword.scale = Vector2(_side(), 1.0) * 0.75
		$Sword.rotation = SWORD_HELD * _side()

	_glow = lerpf(_glow, voice_level, 1.0 - exp(-10.0 * delta))
	$Light.energy = 1.5 * _glow


func _side() -> float:
	return -1.0 if $Sprite.flip_h else 1.0

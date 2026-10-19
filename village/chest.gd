class_name Chest
extends Thing
## A chest, which opens with its key.

## The open chest, in Tiny Dungeon's tiles.
const OPEN_FRAME := 91

## The name of its key.
@export var key := ""
## What's inside, hidden until the chest opens.
@export var treasure: Thing

var opened := false


func open() -> void:
	opened = true
	$Sprite.frame = OPEN_FRAME
	$Sound.play()
	treasure.show()

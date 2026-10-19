class_name Lamp
extends StaticBody2D
## A lamp post, which Pipecat can light.

var lit := false


func light() -> void:
	lit = true
	$Sprite.frame = 1
	$Sound.play()
	create_tween().tween_property($Light, "energy", 0.9, 0.6)

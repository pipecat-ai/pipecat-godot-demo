extends Node
## What the whole game does, whatever screen it's on: it sizes the window, goes
## fullscreen with F or F11, and plays the music, which carries on from one
## screen to the next.

## How loud the music is, in dB, and how much quieter while it's ducked, e.g.
## while the player or Pipecat speak.
const MUSIC_DB := -32.0
const DUCK_DB := 10.0

## Whether the music is quieter, for now.
var duck := false

var _music := AudioStreamPlayer.new()


func _ready() -> void:
	_fit_window()
	_music.stream = load("res://assets/sounds/music.ogg")
	_music.volume_db = MUSIC_DB
	add_child(_music)
	_music.play()


func _process(delta: float) -> void:
	var volume_db := MUSIC_DB - (DUCK_DB if duck else 0.0)
	_music.volume_db = move_toward(_music.volume_db, volume_db, 20.0 * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fullscreen"):
		var fullscreen := get_window().mode == Window.MODE_FULLSCREEN
		get_window().mode = Window.MODE_WINDOWED if fullscreen else Window.MODE_FULLSCREEN


## Makes the window bigger on high-DPI screens where the system doesn't, e.g.
## twice as big at 192 DPI, as long as it fits on the screen.
func _fit_window() -> void:
	if Engine.is_embedded_in_editor() or DisplayServer.screen_get_scale() > 1.0:
		return
	var window := get_window()
	var fits := DisplayServer.screen_get_usable_rect().size / window.size
	var times := mini(roundi(DisplayServer.screen_get_dpi() / 96.0), mini(fits.x, fits.y))
	if times > 1:
		window.size *= times
		window.move_to_center()

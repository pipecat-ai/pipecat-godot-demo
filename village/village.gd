extends Node2D
## The village, and everything Pipecat can do in it.
##
## The game owns the village. When Pipecat's bot is ready, the game tells it
## what's in the village, and keeps its game worker up to date with what's in it
## now. It tells the bot when something happens that Pipecat reacts to, like
## ghosts showing up. When the game worker asks for one of Pipecat's actions,
## the game does it, and answers with how it went.

const GHOST := preload("res://village/ghost.tscn")

## How often the game worker hears the game's state, at most, in seconds.
const STATE_TIME := 0.25
## How close the player needs to be to a place to be at it, and to an item to
## pick it up, in pixels.
const NEAR := 24.0
const REACH := 10.0
## When ghosts come, in seconds: the first ones after Pipecat is ready, and
## then every once in a while, unless there are too many around.
const FIRST_GHOSTS := 30.0
const MORE_GHOSTS := Vector2(30.0, 75.0)
const MAX_GHOSTS := 10
## What goes somewhere new every game, and where, in tiles: anywhere in the
## west, the middle or the east of the village, each in a different one, so
## they're far from each other.
const SCATTERED := ["iron key", "old chest", "big chest"]
const PARTS := [Vector2i(2, 6), Vector2i(12, 16), Vector2i(22, 27)]
## How many ghosts come at once, and how many of them are big ones.
const GHOSTS := Vector2i(3, 5)
const BIG_GHOSTS := 0.25
## How long the subtitles stay once nobody's speaking, in seconds: a moment,
## and the time to read them, at so many characters a second.
const SUBTITLES_TIME := 2.0
const READING_SPEED := 15.0
## Where ghosts come from, just off the screen.
const GHOST_SPAWNS := {
	"the woods": Vector2(488, 216),
	"the north": Vector2(232, -8),
	"the west": Vector2(-8, 152),
	"the east": Vector2(488, 72),
	"the south": Vector2(152, 280),
}

var _user_speaking := false
var _user_text := ""
var _cat_text := ""
var _cat_answered := false
var _cat_speaking := false
var _subtitles_left := 0.0
var _player_place: Thing
var _last_state := {}
var _state_in := 0.0
var _first_message := ""
var _ghosts_in := FIRST_GHOSTS

@onready var pipecat: PipecatClient = $PipecatClient
@onready var player: Player = $Objects/Player
@onready var cat: Cat = $Objects/Cat
@onready var status: Label = $UI/Status
@onready var user_subtitle: Label = $UI/Subtitles/User
@onready var cat_subtitle: Label = $UI/Subtitles/Cat


func _ready() -> void:
	# The game's options, after -- on the command line. PipecatClient connects
	# once the scene is ready, so they apply.
	pipecat.start_url = _option("--start-url", pipecat.start_url)
	pipecat.api_key = _option("--api-key", OS.get_environment("PIPECAT_API_KEY"))
	pipecat.use_microphone = not OS.get_cmdline_user_args().has("--no-microphone")
	_first_message = _option("--say", "")

	pipecat.bot_ready.connect(_on_bot_ready)
	pipecat.disconnected.connect(func(): status.text = "Disconnected")
	pipecat.error.connect(func(message: String): status.text = "Error: " + message)
	pipecat.user_started_speaking.connect(_on_user_started_speaking)
	pipecat.user_stopped_speaking.connect(func(): _user_speaking = false)
	pipecat.user_transcript.connect(_on_user_transcript)
	pipecat.bot_started_speaking.connect(_on_bot_started_speaking)
	pipecat.bot_stopped_speaking.connect(func(): _cat_speaking = false)
	pipecat.bot_interrupted.connect(_on_bot_interrupted)
	pipecat.bot_output.connect(_on_bot_output)
	pipecat.server_message.connect(_on_server_message)
	player.scared.connect(_on_player_scared)
	player.inventory.child_entered_tree.connect(_on_player_got)

	_scatter()
	cat.grid = _walkable()
	cat.follow(player)
	status.text = "Starting the bot..."


func _process(delta: float) -> void:
	cat.voice_level = pipecat.get_bot_voice_level()
	player.voice_level = pipecat.get_microphone_level() if _user_speaking else 0.0
	# The music gets quieter while the player or Pipecat speak.
	Game.duck = _user_speaking or _cat_speaking

	# The subtitles fade away, once there's been time to read them.
	if not _user_speaking and not _cat_speaking:
		_subtitles_left -= delta
	$UI/Subtitles.modulate.a = clampf(_subtitles_left / 0.5, 0.0, 1.0)
	if _subtitles_left <= 0.0 and _cat_answered:
		_clear_subtitles()

	# The player picks up what they walk over.
	for item: Thing in get_tree().get_nodes_in_group("items"):
		if item.visible and item.global_position.distance_to(player.global_position) < REACH:
			_player_picks_up(item)

	# The player opens the chests they walk up to.
	var place := _place_near(player.global_position)
	if place != _player_place:
		_player_place = place
		var chest := place as Chest
		if chest and not chest.opened:
			_player_opens(chest)

	if not pipecat.is_bot_ready():
		return

	# The game worker hears the game's state whenever it changes, a few times a
	# second at most.
	_state_in -= delta
	if _state_in <= 0.0:
		_state_in = STATE_TIME
		var state := _state()
		if state != _last_state:
			_last_state = state
			pipecat.send_client_message("state", state)
	_ghosts_in -= delta
	if _ghosts_in <= 0.0:
		_ghosts_in = randf_range(MORE_GHOSTS.x, MORE_GHOSTS.y)
		if get_tree().get_nodes_in_group("ghosts").size() < MAX_GHOSTS:
			_ghosts_come()


func _exit_tree() -> void:
	Game.duck = false


func _unhandled_input(event: InputEvent) -> void:
	# Back to the title screen, which ends the session with the bot.
	if event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file("res://title/title.tscn")


func _option(option: String, default: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(option)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else default


func _on_bot_ready() -> void:
	pipecat.send_client_message("village", _describe_village())
	if _first_message:
		pipecat.send_text(_first_message)
	status.text = "Say something! (Use headphones, so Pipecat doesn't hear itself.)"


## Tells Pipecat's bot something that happened in the game, for Pipecat to react
## to, e.g. to warn the player.
func _tell(text: String) -> void:
	if pipecat.is_bot_ready():
		pipecat.send_client_message("event", {"text": text})


#
# Pipecat's functions
#


## The game worker's actions for Pipecat, which it sends one at a time, with
## fights alongside them. It hears how each went once it's done.
func _on_server_message(data: Variant) -> void:
	if not data is Dictionary or data.get("type") != "do_action":
		return
	var what: String = data.get("what") if data.get("what") is String else ""
	var result := await _act(data.get("action", ""), what)
	pipecat.send_client_message("action_done", {"id": data.get("id"), "result": result})


func _act(action: String, what: String) -> String:
	match action:
		"go_to":
			return await _go_to(what)
		"pick_up":
			return await _pick_up(what)
		"give":
			return await _give()
		"open_chest":
			return await _open_chest(what)
		"light_lamps":
			return await _light_lamps()
		"follow":
			cat.follow(player)
			return "You're following your friend."
		"fight_ghosts":
			return await _fight_ghosts()
	return "You can't %s." % action


func _go_to(place_name: String) -> String:
	var place := _find("places", place_name)
	if not place:
		return "There's no %s. The places are: %s." % [place_name, _names("places")]
	await cat.walk_to(place.global_position)
	return "You're at the %s." % place.name


func _pick_up(item_name: String) -> String:
	var item := _find("items", item_name)
	if not item:
		var has := player.inventory.get_children().map(func(thing): return thing.name)
		return "There's no %s around. The items are: %s. Your friend has: %s." % [
			item_name, _names("items"), ", ".join(has) if has else "nothing"
		]
	if cat.carrying:
		return "You're already carrying the %s." % cat.carrying.name
	await cat.walk_to(item.global_position)
	if not item.is_in_group("items"):
		cat.follow(player)
		return "Your friend picked up the %s first." % item.name
	item.remove_from_group("items")
	cat.carry(item)
	_got(item)
	cat.follow(player)
	return "You picked up the %s." % item.name


func _give() -> String:
	if not cat.carrying:
		return "You're not carrying anything."
	await cat.walk_to(cat.beside(player))
	var item := cat.drop()
	player.take(item)
	_got(item)
	cat.follow(player)
	if item.name == "sword":
		return "You gave the sword to your friend. They can fight ghosts too now, with Space."
	return "You gave the %s to your friend." % item.name


func _open_chest(chest_name: String) -> String:
	var chest := _find("places", chest_name) as Chest
	if not chest:
		return "There's no %s. The places are: %s." % [chest_name, _names("places")]
	if chest.opened:
		return "The %s is already open." % chest.name

	# Pipecat doesn't know which key opens which chest: it tries the key it
	# carries, or one the player has, which it takes from them.
	var took_key := false
	if not cat.carrying or not cat.carrying.name.ends_with("key"):
		var keys := player.inventory.get_children().filter(
			func(item): return item.name.ends_with("key")
		)
		if keys and cat.carrying:
			return "Your friend has a key, but you're carrying the %s." % cat.carrying.name
		if keys:
			await cat.walk_to(cat.beside(player))
			var key := player.give(keys[0].name)
			# E.g. if the player opened a chest themselves meanwhile.
			if not key:
				cat.follow(player)
				return "Your friend doesn't have the %s anymore." % keys[0].name
			cat.carry(key)
			took_key = true

	# Without a key, Pipecat goes anyway, to see.
	await cat.walk_to(chest.global_position)
	if not cat.carrying or not cat.carrying.name.ends_with("key"):
		cat.follow(player)
		return "The %s is locked, and neither of you has a key." % chest.name
	var how := "You took the %s from your friend" if took_key else "You tried the %s"
	if cat.carrying.name != chest.key:
		cat.follow(player)
		return (how + ", but it doesn't open the %s. You still have it.") % [
			cat.carrying.name, chest.name
		]
	# The key stays in the lock, and Pipecat stays by the chest.
	cat.drop().queue_free()
	chest.open()
	var treasure := chest.treasure
	return (
		how + ", and it opened the %s. Inside, there's a %s: %s You're still by the chest:"
		+ " ask your friend if they want you to bring it to them."
	) % [chest.key, chest.name, treasure.name, treasure.description]


func _light_lamps() -> String:
	var lamps := get_tree().get_nodes_in_group("lamps").filter(func(lamp: Lamp): return not lamp.lit)
	if lamps.is_empty():
		return "The lamps are already lit."
	for lamp: Lamp in lamps:
		await cat.walk_to(lamp.global_position)
		lamp.light()
	cat.follow(player)
	return "You lit all the lamps."


#
# What the player does
#


func _player_picks_up(item: Thing) -> void:
	item.remove_from_group("items")
	player.take(item)
	_got(item)


func _player_opens(chest: Chest) -> void:
	var key := player.give(chest.key)
	if not key:
		status.text = "The %s is locked." % chest.name
		return
	# The key stays in the lock.
	key.queue_free()
	chest.open()


## Sounds as the player or Pipecat get something.
func _got(item: Thing) -> void:
	if item.name.ends_with("key"):
		$Sounds/Key.play()
	else:
		$Sounds/PickUp.play()


func _on_player_got(item: Node) -> void:
	if item.name == "sword":
		status.text = "Press Space to swing the sword."


#
# The village
#


func _describe_village() -> Dictionary:
	var village := {}
	for group in ["places", "items"]:
		var things := {}
		for thing: Thing in get_tree().get_nodes_in_group(group):
			if thing.visible:
				things[thing.name] = thing.description
		village[group] = things
	var lamps := get_tree().get_nodes_in_group("lamps").size()
	village["lamps"] = "%d lamp posts along the paths. They're not lit yet." % lamps
	village["your friend"] = (
		"Your friend has %d hearts. They can pick things up and open chests too." % Player.MAX_HEARTS
	)
	return village


## Puts the key and the chests somewhere new, each in a different part of the
## village, where there's room. A chest's treasure shows up on its right.
func _scatter() -> void:
	var parts := PARTS.duplicate()
	parts.shuffle()
	for i in SCATTERED.size():
		var thing: Thing = $Objects.get_node(SCATTERED[i])
		var spot := Vector2i(randi_range(parts[i].x, parts[i].y), randi_range(2, 13))
		while not _has_room(spot) or not _has_room(spot + Vector2i.RIGHT):
			spot = Vector2i(randi_range(parts[i].x, parts[i].y), randi_range(2, 13))
		thing.position = $Ground.map_to_local(spot)
		if thing is Chest:
			thing.treasure.position = $Ground.map_to_local(spot + Vector2i.RIGHT)
		thing.description += " It's near the %s." % _landmark_near(thing.position).name


## The village's tiles, with what Pipecat can't walk through: trees, buildings,
## and things like the well, the lamps and the chests.
func _walkable() -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = $Ground.get_used_rect()
	grid.cell_size = Vector2(16, 16)
	grid.offset = grid.cell_size / 2
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for tile in $Buildings.get_used_cells():
		grid.set_point_solid(tile)
	for node in $Objects.get_children():
		if node is StaticBody2D:
			grid.set_point_solid($Ground.local_to_map(node.position))
	return grid


## Whether a tile is free, with nothing next to it either.
func _has_room(tile: Vector2i) -> bool:
	if $Buildings.get_cell_source_id(tile) != -1:
		return false
	for node: Node2D in $Objects.get_children():
		var other: Vector2i = $Ground.local_to_map(node.position)
		if maxi(absi(tile.x - other.x), absi(tile.y - other.y)) <= 1:
			return false
	return true


## The place, other than a chest, nearest to `where`, to tell where things are.
func _landmark_near(where: Vector2) -> Thing:
	var nearest: Thing
	var distance := INF
	for place: Thing in get_tree().get_nodes_in_group("places"):
		if not place is Chest and place.position.distance_to(where) < distance:
			nearest = place
			distance = place.position.distance_to(where)
	return nearest


## What's in the village now, for the game worker to look around.
func _state() -> Dictionary:
	var items := {}
	for item: Thing in get_tree().get_nodes_in_group("items"):
		if item.visible:
			items[item.name] = item.description
	var chests := {}
	for place in get_tree().get_nodes_in_group("places"):
		if place is Chest:
			chests[place.name] = "open" if place.opened else "locked"
	var near := _place_near(player.global_position)
	var lamps := get_tree().get_nodes_in_group("lamps")
	var ghosts := get_tree().get_nodes_in_group("ghosts")
	return {
		"your friend": {
			"hearts": player.hearts,
			"has": player.inventory.get_children().map(func(item): return item.name),
			"near": near.name if near else "nothing",
		},
		"you": {"carrying": cat.carrying.name if cat.carrying else "nothing"},
		"items": items,
		"chests": chests,
		"lamps lit": "%d of %d" % [lamps.filter(func(lamp): return lamp.lit).size(), lamps.size()],
		"ghosts": {
			"around": ghosts.size(),
			"big": ghosts.filter(func(ghost): return ghost.big).size(),
		},
	}


## Finds the place or item the LLM means, e.g. the key for "the old key".
func _find(group: String, what: String) -> Thing:
	what = what.to_lower()
	for thing: Thing in get_tree().get_nodes_in_group(group):
		if thing.visible and what.contains(thing.name):
			return thing
	return null


func _names(group: String) -> String:
	var names := get_tree().get_nodes_in_group(group).filter(func(thing): return thing.visible)
	return ", ".join(names.map(func(thing): return thing.name))


func _place_near(where: Vector2) -> Thing:
	var nearest: Thing
	var distance := NEAR
	for place: Thing in get_tree().get_nodes_in_group("places"):
		if place.global_position.distance_to(where) < distance:
			nearest = place
			distance = place.global_position.distance_to(where)
	return nearest


#
# Ghosts
#


## Ghosts come from a few places at once.
func _ghosts_come() -> void:
	var spawns := GHOST_SPAWNS.keys()
	spawns.shuffle()
	spawns.resize(randi_range(GHOSTS.x, GHOSTS.y))
	var big := 0
	for spawn in spawns:
		var ghost: Ghost = GHOST.instantiate()
		ghost.target = player
		ghost.position = GHOST_SPAWNS[spawn]
		ghost.big = randf() < BIG_GHOSTS
		big += int(ghost.big)
		$Objects.add_child(ghost)
	$Sounds/Ghosts.play()
	var places := ", ".join(PackedStringArray(spawns))
	var text := "%d ghosts are coming, from %s!" % [spawns.size(), places]
	if big:
		text += " %d of them are big, and take two hits." % big
	_tell(text)


## Fights the ghosts around now, until they're gone. Ghosts that come later need
## another fight. Pipecat comes back to the player to fight, as that's where the
## ghosts go.
func _fight_ghosts() -> String:
	var ghosts := get_tree().get_nodes_in_group("ghosts")
	if ghosts.is_empty():
		return "There are no ghosts around."
	cat.follow(player)
	cat.targets = ghosts
	while cat.targets:
		await get_tree().create_timer(0.2).timeout
	var result := "The ghosts you fought are gone. Your friend has %s of %d hearts left." % [
		String.num(player.hearts), Player.MAX_HEARTS
	]
	var more := get_tree().get_nodes_in_group("ghosts").size()
	if more:
		result += " %d more ghosts came meanwhile: you only fight them if your friend asks." % more
	return result


func _on_player_scared() -> void:
	if player.hearts > 0:
		return
	# Too scared: the player faints, and wakes up at home.
	player.position = $Objects/house.position + Vector2(0, 16)
	player.hearts = Player.MAX_HEARTS
	_tell("The ghosts scared your friend so much that they fainted! They woke up at home.")


#
# Subtitles
#


func _on_user_started_speaking() -> void:
	_user_speaking = true
	_start_exchange()


func _on_user_transcript(text: String, final: bool) -> void:
	text = text.strip_edges()
	if not text:
		return
	# E.g. for text, which comes without the player speaking.
	_start_exchange()
	# The player's turn comes in pieces: the finished ones, and the one they're
	# saying now.
	var turn := text if not _user_text else _user_text + " " + text
	if final:
		_user_text = turn
	user_subtitle.text = "You: " + turn
	_show_subtitles()


## Keeps the subtitles long enough to read them.
func _show_subtitles() -> void:
	var length := user_subtitle.text.length() + cat_subtitle.text.length()
	_subtitles_left = SUBTITLES_TIME + length / READING_SPEED


## Starts a new exchange, once Pipecat answered the last one. Until then, the
## player is still taking their turn.
func _start_exchange() -> void:
	status.text = ""
	if _cat_answered:
		_clear_subtitles()


func _clear_subtitles() -> void:
	_cat_answered = false
	_user_text = ""
	_cat_text = ""
	user_subtitle.text = ""
	cat_subtitle.text = ""


func _on_bot_started_speaking() -> void:
	_cat_speaking = true
	# Something new, e.g. a warning, after Pipecat answered the last thing.
	if _cat_answered:
		_clear_subtitles()


func _on_bot_interrupted() -> void:
	_cat_text = ""
	cat_subtitle.text = ""


func _on_bot_output(text: String) -> void:
	# The default font has no curly apostrophes.
	text = text.replace("’", "'").replace("‘", "'")
	_cat_answered = true
	_cat_text = text if not _cat_text else _cat_text + " " + text
	cat_subtitle.text = "Pipecat: " + _cat_text
	_show_subtitles()

# A noraebang fight, gray-box: the arena, the 반주기 lyric panel, the freeze at
# each blank, the result cards and the game over. It runs a song file through a
# SongClock (never audio directly) and FightLogic (the rules); nothing here is
# specific to one boss. Attack and counter ids resolve through FightRegistry.
#   Controls at a blank: W/S (or the arrows) and Enter, or a click. X, or a click on
#   the 눈치 eyes in the HUD, crosses out one wrong option for 1 눈치 (once per blank).
#   A known loaded card adds a 4th option; the song's lighting modes (normal, flicker,
#   frantic, and a blank's blackout) come from the song file, but only play when
#   tuning.json's fight_lighting_effects is true (default false: normal light throughout).
#   After a survival win the boss's line and her taunts play, then the end card.
#   World starts it (--fight <boss>, or resuming a saved fight); the tests and the
#   capture mode drive it with step() and pick_*().
#
# SPDX-License-Identifier: AGPL-3.0-or-later
extends Node3D

signal result_ready(result: Dictionary)
signal ended

enum State { PLAYING, FREEZE, BEAT, RESULT, END, GAME_OVER, AFTERMATH }

const TuningScript := preload("res://scripts/tuning.gd")
const FONT := preload("res://art/fonts/NotoSansKR/NotoSansKR-VF.ttf")
const END_TEXT := "END OF BUILD 4b"
const SCORE_FORMAT := "점수: %d점"
const RETRY_TEXT := "다시 부른다"
const BEAT_TIME := 1.6
const AUTO_DELAY := 0.8
const AUTO_RESULT_DELAY := 1.0
const ATTACKER_X := 4.5
const TARGET_X := -4.5
const REACH_GAP := 0.9
const LINE_H := 66.0
const CLIP_SIZE := Vector2(1440, 200)
const FLASH_ALPHA := 0.55
const FLASH_TIME := 0.4
const SHAKE_TIME := 0.45
const CAMERA_BASE := Vector3(0, 2.2, 10.5)
const SUN_ENERGY := 0.9
const AMBIENT_ENERGY := 0.6
const AMBIENT_COLOR := Color(0.75, 0.72, 0.7)
const FRANTIC_COLOR := Color(1.0, 0.2, 0.15)
const CROSS_KEY := KEY_X
const HINT_CROSS := "X or click the eyes: cross out a wrong option, costs 1 nunchi [placeholder]"
const HINT_NO_NUNCHI := "No nunchi left to cross out [placeholder]"
const HINT_USED := "Already crossed out on this blank [placeholder]"

## "", "right", "wrong", "mixed" (wrong on every third blank) or "cross" (a cross-out on
## every blank, then right): answers by itself.
var auto_mode := ""
## True: the owner calls step(); false: _process does.
var manual := false
var time_scale := 1.0
var state: State = State.PLAYING
var song: Dictionary = {}
var logic: FightLogic
var clock: SongClock
var registry: FightRegistry
var last_result: Dictionary = {}
var options: Array[String] = []
var selected := 0
## Which card is up: "", "revenge", "survival", "gameover" or "end".
var card_kind := ""
var retries := 0
var bursts := 0
var flashes := 0
var shakes := 0
## How many loaded blanks' attacks have landed with the nastier flourish.
var loaded_flourishes := 0
var lost_signals := 0
var freeze_left := 0.0
## What the lights are doing now: "normal", "flicker", "frantic" or "blackout".
var lighting := "normal"
## tuning.json's fight_lighting_effects. False: the song's lighting data is ignored and
## the lights stay normal (as in phase 1) all fight.
var lighting_effects := false
## After a survival win: the lines to play, [{"speaker", "text", "card"}], and the one showing.
var aftermath: Array[Dictionary] = []
var aftermath_index := -1

var _seed := 0
var _freeze_time := 0.0
var _beat_left := 0.0
var _result_time := 0.0
var _attack_from_x := ATTACKER_X
var _attack_back := false
var _attack: MeshInstance3D
var _line_labels: Array[Label] = []
var _line_texts: Array[String] = []
var _lyric_col: Control
var _option_box: VBoxContainer
var _option_buttons: Array[Button] = []
var _timer_bar_bg: ColorRect
var _timer_bar: ColorRect
var _timer_label: Label
var _banner: Label
var _flash_rect: ColorRect
var _card_layer: CanvasLayer
var _card_bg: ColorRect
var _card_splats: Control
var _card_title: Label
var _card_body: Label
var _card_score: Label
var _card_hint: Label
var _retry_button: Button
var _set: Node3D
var _sun: DirectionalLight3D
var _env: Environment
var _camera: Camera3D
var _light_overlay: ColorRect
var _light_override := ""
var _light_time := 0.0
var _shake_left := 0.0
var _shake_strength := 0.0
var _loaded_label: Label
var _cross_hint: Label
var _after_panel: Panel
var _after_speaker: Label
var _after_text: Label
var _eunju_pos := Vector3(ATTACKER_X, 0.0, -1.0)
var _boram_pos := Vector3(TARGET_X, 0.0, -1.0)


## Call before add_child. `seed_number` shuffles the options (World passes the launch seed).
## `song_clock` replaces the silent clock (an audio backend, or a test's recording one).
func setup(song_data: Dictionary, seed_number: int, auto := "", manual_steps := false, song_clock: SongClock = null) -> void:
	song = song_data
	clock = song_clock
	_seed = seed_number
	auto_mode = auto
	manual = manual_steps


func _ready() -> void:
	registry = FightRegistry.new()
	if clock == null:
		clock = SilentSongClock.new()
	var cfg: Dictionary = TuningScript.fight_config()
	lighting_effects = cfg["lighting_effects"]
	logic = FightLogic.new(song, _seed, GameState, cfg["wrong_halves"])
	GameState.fight_lost.connect(func(): lost_signals += 1)
	_build_set()
	_build_ui()
	_build_lines()
	start_song()
	set_process(not manual)


func _process(delta: float) -> void:
	step(delta * time_scale)


## From the top: the song clock at 0, blank 1 next.
func start_song() -> void:
	clock.play()
	state = State.PLAYING
	card_kind = ""
	_card_layer.visible = false
	_retry_button.visible = false
	_option_box.visible = false
	_hide_timer()
	_banner.text = ""
	_loaded_label.visible = false
	_cross_hint.visible = false
	_after_panel.visible = false
	aftermath = []
	aftermath_index = -1
	_light_override = ""
	_shake_left = 0.0
	_camera.position = CAMERA_BASE
	_clear_attack()
	_update_lighting(0.0)
	for i in song["lines"].size():
		_line_texts[i] = _display_text(i)
	_update_scroll()


func step(delta: float) -> void:
	match state:
		State.PLAYING:
			clock.tick(delta)
			_update_scroll()
			if logic.has_blank() and clock.get_position() >= float(logic.current()["time"]):
				clock.seek(float(logic.current()["time"]))
				_enter_freeze()
			elif not logic.has_blank() and clock.get_position() >= float(song["length"]):
				_finish_song()
		State.FREEZE:
			_freeze_time += delta
			freeze_left = maxf(freeze_left - delta, 0.0)
			_update_attack(1.0 - freeze_left / float(song["countdown"]))
			_update_timer()
			if auto_mode != "" and _freeze_time >= AUTO_DELAY:
				_auto_pick()
			elif freeze_left <= 0.0:
				_resolve("")
		State.BEAT:
			_beat_left -= delta
			_animate_beat(1.0 - maxf(_beat_left, 0.0) / BEAT_TIME)
			if _beat_left <= 0.0:
				_after_beat()
		State.RESULT:
			_result_time += delta
			if auto_mode != "" and _result_time >= AUTO_RESULT_DELAY:
				_advance_result()
		State.AFTERMATH:
			_result_time += delta
			if auto_mode != "" and _result_time >= AUTO_RESULT_DELAY:
				_next_aftermath()
	_update_shake(delta)
	_update_lighting(delta)


# ── Input ──────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	var clicked: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	match state:
		State.FREEZE:
			if event.is_action_pressed("ui_up"):
				_select(selected - 1)
			elif event.is_action_pressed("ui_down"):
				_select(selected + 1)
			elif event.is_action_pressed("confirm"):
				pick(selected)
			elif event is InputEventKey and event.pressed and event.keycode == CROSS_KEY:
				cross_out()
			elif clicked and _on_nunchi_eyes(event.position):
				cross_out()
		State.RESULT:
			if event.is_action_pressed("confirm") or clicked:
				_advance_result()
		State.AFTERMATH:
			if event.is_action_pressed("confirm") or clicked:
				_next_aftermath()
		State.GAME_OVER:
			if event.is_action_pressed("confirm"):
				retry()


## Moves the highlight to option `i` (wrapping), skipping the crossed-out one in the
## direction of travel.
func _select(i: int) -> void:
	if options.is_empty():
		return
	var dir := 1 if i >= selected else -1
	var target := posmod(i, options.size())
	for tries in options.size():
		if logic.crossed == "" or options[target] != logic.crossed:
			break
		target = posmod(target + dir, options.size())
	selected = target
	_paint_options()


## Chooses option `i` of the shuffled list (what Enter and a click call).
func pick(i: int) -> void:
	if state == State.FREEZE and i >= 0 and i < options.size() and options[i] != logic.crossed:
		_resolve(options[i])


## Crosses out one wrong option for 1 눈치 (once per blank). False when it isn't allowed.
func cross_out() -> bool:
	if state != State.FREEZE:
		return false
	var removed := logic.cross_out()
	if removed == "":
		_update_cross_hint()
		return false
	var at := options.find(removed)
	var b := _option_buttons[at]
	b.disabled = true
	var strike: ColorRect = b.get_node("Strike")
	var width := b.get_theme_font("font").get_string_size(removed, HORIZONTAL_ALIGNMENT_LEFT, -1, 40).x
	strike.size = Vector2(width + 24.0, 5.0)
	strike.position = Vector2((b.custom_minimum_size.x - strike.size.x) / 2.0, b.custom_minimum_size.y / 2.0)
	strike.visible = true
	if selected == at:
		_select(selected + 1)
	_paint_options()
	_update_cross_hint()
	return true


func _on_nunchi_eyes(at: Vector2) -> bool:
	var eyes := get_tree().get_first_node_in_group("nunchi_display") as Control
	return eyes != null and eyes.is_visible_in_tree() and eyes.get_global_rect().has_point(at)


func _update_cross_hint() -> void:
	if logic.crossed != "":
		_cross_hint.text = HINT_USED
	elif GameState.nunchi < 1:
		_cross_hint.text = HINT_NO_NUNCHI
	else:
		_cross_hint.text = HINT_CROSS


## Scripted helpers for the tests, the auto modes and the captures.
func pick_right() -> void:
	if state == State.FREEZE:
		_resolve(str(logic.current()["answer"]))


func pick_wrong() -> void:
	if state == State.FREEZE:
		for o in options:
			if o != logic.current()["answer"] and o != logic.crossed:
				_resolve(o)
				return


func _auto_pick() -> void:
	if auto_mode == "cross" and cross_out():
		return
	var wrong_now: bool = auto_mode == "wrong" or (auto_mode == "mixed" and int(logic.current()["n"]) % 3 == 0)
	if wrong_now:
		pick_wrong()
	else:
		pick_right()


## Steps in `dt` slices until the next freeze (or `limit` seconds pass). True if frozen.
func play_to_freeze(limit := 120.0, dt := 0.05) -> bool:
	var t := 0.0
	while state != State.FREEZE and t < limit and state != State.GAME_OVER and state != State.RESULT:
		step(dt)
		t += dt
	return state == State.FREEZE


## Steps until the beat after an answer is over (the song plays on, or a card is up).
func finish_beat(dt := 0.05) -> void:
	var guard := 0
	while state == State.BEAT and guard < 1000:
		step(dt)
		guard += 1


# ── The freeze ─────────────────────────────────────────────────────────

func _enter_freeze() -> void:
	clock.pause()
	state = State.FREEZE
	var blank := logic.current()
	options = logic.options_for(blank)
	selected = 0
	_freeze_time = 0.0
	freeze_left = float(song["countdown"])
	_line_texts[_line_of(blank)] = _display_text(_line_of(blank), "[ ____ ]")
	_apply_line_texts()
	_fill_option_buttons()
	_option_box.visible = true
	_timer_bar_bg.visible = true
	_timer_bar.visible = true
	_timer_label.visible = true
	_banner.text = ""
	_loaded_label.visible = false
	_light_override = str(blank.get("light", ""))
	_update_lighting(0.0)
	_update_cross_hint()
	_cross_hint.visible = true
	_spawn_attack(registry.attack(str(blank["attack"])))
	_update_attack(0.0)
	_update_timer()


func _resolve(picked: String) -> void:
	var blank := logic.current()
	var res := logic.answer(picked)
	if res.is_empty():
		return
	last_result = res
	state = State.BEAT
	_beat_left = BEAT_TIME
	_attack_back = res["right"]
	_attack_from_x = _attack.position.x if _attack != null else ATTACKER_X
	var idx := _line_of(blank)
	_line_texts[idx] = _display_text(idx, str(blank["answer"]))
	_apply_line_texts()
	_paint_options(picked, str(blank["answer"]))
	_hide_timer()
	_cross_hint.visible = false
	if res["right"]:
		var counter := registry.counter(str(blank["counter"]))
		_banner.text = "RIGHT   [placeholder] counter: %s (%s)" % [counter["id"], counter["tone"]]
		_banner.modulate = Color(0.6, 1.0, 0.6)
	else:
		var why := "TIME UP" if res["timeout"] else "WRONG"
		_banner.text = "%s   answer: %s   -%s heart" % [why, blank["answer"], _hearts_cost_text()]
		_banner.modulate = Color(1.0, 0.45, 0.45)
		_burst(_boram_pos + Vector3(0, 1.1, 0), 80, 1.0)
		_flash()
		if res["loaded"]:
			_loaded_flourish(str(res["card"]))
	_animate_beat(0.0)


func _hearts_cost_text() -> String:
	var halves: int = logic.wrong_halves
	return "%d" % (halves / 2) if halves % 2 == 0 else "%.1f" % (halves / 2.0)


func _after_beat() -> void:
	_option_box.visible = false
	_banner.text = ""
	_loaded_label.visible = false
	_light_override = ""
	_update_lighting(0.0)
	_clear_attack()
	if logic.lost():
		_show_game_over()
		return
	state = State.PLAYING
	clock.resume()


# ── Ending ─────────────────────────────────────────────────────────────

func _finish_song() -> void:
	clock.pause()
	var result := logic.finish()
	if result.is_empty():
		push_error("Fight: song ended with blanks unanswered or no hearts")
		return
	last_result = result
	state = State.RESULT
	_result_time = 0.0
	card_kind = str(result["outcome"])
	var card_text: String = str(song["outcomes"][card_kind].get("card", ""))
	_card_splats.visible = card_kind == "revenge"
	_card_hint.text = "Press Enter"
	_card_score.text = SCORE_FORMAT % int(result["score"])
	_retry_button.visible = false
	if card_kind == "revenge":
		_card_bg.color = Color(0.25, 0.0, 0.02, 0.94)
		_card_title.text = "REVENGE WIN"
		_card_body.text = "%s\n\nHearts restored to full." % card_text
		_scatter_splats()
		_burst(_eunju_pos + Vector3(0, 1.0, 0), 160, 1.6)
		_burst(_eunju_pos + Vector3(-0.8, 0.6, 0.3), 120, 1.3)
		_flash()
	else:
		_card_bg.color = Color(0.08, 0.1, 0.16, 0.94)
		_card_title.text = "SURVIVAL WIN"
		_card_body.text = card_text
	aftermath = _build_aftermath(card_kind)
	aftermath_index = -1
	_card_layer.visible = true
	result_ready.emit(result)


## The boss's spoken line, then one taunt per known loaded card in card-list order.
## Only a survival win has any: a dead boss doesn't taunt.
func _build_aftermath(outcome: String) -> Array[Dictionary]:
	var lines: Array[Dictionary] = []
	if outcome != "survival":
		return lines
	var data: Dictionary = song["outcomes"]["survival"]
	var speaker := str(data.get("speaker", ""))
	if str(data.get("line", "")) != "":
		lines.append({"speaker": speaker, "text": str(data["line"]), "card": ""})
	for item in logic.known_loaded():
		if str(item.get("taunt", "")) != "":
			lines.append({"speaker": speaker, "text": str(item["taunt"]), "card": str(item["card"])})
	return lines


## Enter or a click on the result card: the aftermath if there is one, else the end card.
func _advance_result() -> void:
	if aftermath.is_empty():
		_show_end()
		return
	state = State.AFTERMATH
	_result_time = 0.0
	_card_splats.visible = false
	for l in [_card_title, _card_body, _card_score, _card_hint]:
		l.text = ""
	_after_panel.visible = true
	_next_aftermath()


func _next_aftermath() -> void:
	aftermath_index += 1
	_result_time = 0.0
	if aftermath_index >= aftermath.size():
		_show_end()
		return
	var line := aftermath[aftermath_index]
	_after_speaker.text = line["speaker"]
	_after_text.text = line["text"]


func _show_end() -> void:
	state = State.END
	card_kind = "end"
	_after_panel.visible = false
	_card_splats.visible = false
	_card_bg.color = Color(0, 0, 0, 1)
	_card_title.text = END_TEXT
	_card_body.text = "[placeholder]"
	_card_score.text = ""
	_card_hint.text = ""
	_card_layer.visible = true
	ended.emit()


func _show_game_over() -> void:
	state = State.GAME_OVER
	card_kind = "gameover"
	clock.pause()
	_card_splats.visible = false
	_card_bg.color = Color(0, 0, 0, 1)
	_card_title.text = str(song["game_over"].get("anchor", ""))
	_card_body.text = str(song["game_over"]["line"])
	_card_score.text = ""
	_card_hint.text = ""
	_retry_button.visible = true
	_card_layer.visible = true


## 다시 부른다: hearts and 눈치 back to the fight start, the song from phase 1.
func retry() -> void:
	if state != State.GAME_OVER:
		return
	if not GameState.retry_fight():
		return
	retries += 1
	logic.restart(true)
	last_result = {}
	start_song()


# ── The arena ──────────────────────────────────────────────────────────

func _box(box_name: String, size: Vector3, color: Color, at: Vector3, label := "", label_lift := 0.3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = box_name
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	mesh.position = at
	if label != "":
		var l := Label3D.new()
		l.text = label
		l.font = FONT
		l.font_size = 48
		l.pixel_size = 0.006
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.outline_size = 10
		l.position = Vector3(0, size.y / 2.0 + label_lift, 0)
		l.add_to_group("dev_labels")
		mesh.add_child(l)
	_set.add_child(mesh)
	return mesh


func _build_set() -> void:
	_set = Node3D.new()
	_set.name = "Arena"
	add_child(_set)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.1, 0.1, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = AMBIENT_COLOR
	e.ambient_light_energy = AMBIENT_ENERGY
	env.environment = e
	_env = e
	_set.add_child(env)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-40, 20, 0)
	_sun.light_energy = SUN_ENERGY
	_set.add_child(_sun)
	_box("Floor", Vector3(18, 0.2, 8), Color(0.42, 0.36, 0.3), Vector3(0, -0.1, -2))
	_box("BackWall", Vector3(18, 5, 0.2), Color(0.5, 0.48, 0.45), Vector3(0, 2.5, -5.6))
	_box("Banjugi", Vector3(2.0, 1.5, 0.8), Color(0.2, 0.22, 0.28), Vector3(0, 0.75, -4.7), "반주기")
	_box("Jangsingjang", Vector3(1.4, 2.4, 0.7), Color(0.35, 0.22, 0.14), Vector3(6.6, 1.2, -4.8), "장식장", 0.9)
	_box("ColorTv", Vector3(1.4, 1.0, 0.9), Color(0.3, 0.3, 0.34), Vector3(-7.2, 0.5, -4.7), "컬러 TV")
	_box("Eunju", Vector3(0.9, 1.5, 0.6), Color(0.9, 0.55, 0.65), _eunju_pos + Vector3(0, 0.75, 0), "은주", 1.0)
	_box("EunjuHead", Vector3(0.6, 0.6, 0.6), Color(0.95, 0.8, 0.7), _eunju_pos + Vector3(0, 1.8, 0))
	_box("Boram", Vector3(0.8, 1.3, 0.55), Color(0.4, 0.55, 0.9), _boram_pos + Vector3(0, 0.65, 0), "보람", 1.0)
	_box("BoramHead", Vector3(0.55, 0.55, 0.55), Color(0.95, 0.8, 0.7), _boram_pos + Vector3(0, 1.55, 0))
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = 40.0
	cam.position = CAMERA_BASE
	_camera = cam
	_set.add_child(cam)
	cam.look_at_from_position(cam.position, Vector3(0, 0.9, 0), Vector3.UP)
	cam.current = true


func _spawn_attack(look: Dictionary) -> void:
	_clear_attack()
	_attack = MeshInstance3D.new()
	_attack.name = "Attack"
	var bm := BoxMesh.new()
	bm.size = look["size"]
	_attack.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = look["color"]
	mat.emission_enabled = true
	mat.emission = look["color"]
	mat.emission_energy_multiplier = 0.5
	_attack.material_override = mat
	var l := Label3D.new()
	l.name = "AttackId"
	l.text = ("%s [placeholder]" % look["id"]) if look["placeholder"] else str(look["id"])
	l.font = FONT
	l.font_size = 52
	l.pixel_size = 0.007
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.outline_size = 12
	l.position = Vector3(0, -look["size"].y / 2.0 - 0.4, 0)
	_attack.add_child(l)
	_set.add_child(_attack)


func _clear_attack() -> void:
	if _attack != null and is_instance_valid(_attack):
		_attack.queue_free()
	_attack = null


## `p` 0..1: 은주's hand to just in front of 보람.
func _update_attack(p: float) -> void:
	if _attack == null:
		return
	var from_x := ATTACKER_X - 0.8
	var to_x := TARGET_X + REACH_GAP
	_attack.position = Vector3(lerpf(from_x, to_x, p), 0.9 + 0.4 * sin(PI * p), -1.0)


func _animate_beat(p: float) -> void:
	if _attack == null:
		return
	var to_x := ATTACKER_X - 0.8 if _attack_back else TARGET_X
	_attack.position.x = lerpf(_attack_from_x, to_x, clampf(p * 1.5, 0.0, 1.0))
	if _attack_back:
		_attack.scale = Vector3.ONE * lerpf(1.0, 0.5, p)
	elif p > 0.5:
		_attack.visible = false


func _burst(at: Vector3, amount: int, size: float) -> void:
	bursts += 1
	var p := CPUParticles3D.new()
	p.amount = amount
	p.one_shot = true
	p.explosiveness = 0.95
	p.lifetime = 1.0
	p.direction = Vector3(0, 1, 0)
	p.spread = 75.0
	p.initial_velocity_min = 2.5 * size
	p.initial_velocity_max = 6.0 * size
	p.gravity = Vector3(0, -9.0, 0)
	var sphere := SphereMesh.new()
	sphere.radius = 0.07 * size
	sphere.height = 0.14 * size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.02, 0.05)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = mat
	p.mesh = sphere
	p.position = at
	_set.add_child(p)
	p.emitting = true
	get_tree().create_timer(2.5).timeout.connect(p.queue_free)


## The nastier landing of a loaded blank's attack (all from the registry): extra blood,
## a screen shake and the LOADED label with the card id.
func _loaded_flourish(card: String) -> void:
	var f := registry.loaded_flourish()
	loaded_flourishes += 1
	for i in int(f["extra_splats"]):
		_burst(_boram_pos + Vector3(0.35 * (i + 1), 0.9, 0.2), 110, 1.3)
	_start_shake(float(f["shake"]))
	_loaded_label.text = "%s: %s" % [f["label"], card]
	_loaded_label.visible = true


func _start_shake(strength: float) -> void:
	shakes += 1
	_shake_strength = strength
	_shake_left = SHAKE_TIME if strength > 0.0 else 0.0


func _update_shake(delta: float) -> void:
	if _shake_left <= 0.0:
		return
	_shake_left = maxf(_shake_left - delta, 0.0)
	var fade := _shake_left / SHAKE_TIME
	_camera.position = CAMERA_BASE + Vector3(sin(_light_time * 93.0), cos(_light_time * 71.0), 0.0) * _shake_strength * fade


## The lighting mode now: a blank's own (blackout) from its reveal to the end of its
## counter, else the phase of the line being sung; the cards use normal light.
func _update_lighting(delta: float) -> void:
	_light_time += delta
	if not lighting_effects:
		lighting = "normal"
	elif _light_override != "":
		lighting = _light_override
	elif state == State.RESULT or state == State.AFTERMATH or state == State.END or state == State.GAME_OVER:
		lighting = "normal"
	else:
		var phase := 1
		var t := clock.get_position()
		for l in song["lines"]:
			if float(l["time"]) <= t:
				phase = int(l["phase"])
		lighting = SongData.phase_lighting(song, phase)
	var sun_energy := SUN_ENERGY
	var ambient_energy := AMBIENT_ENERGY
	var color := Color.WHITE
	var ambient_color := AMBIENT_COLOR
	var overlay := Color(0, 0, 0, 0)
	match lighting:
		"flicker":
			if not _flicker_on(5.0):
				sun_energy = 0.12
				ambient_energy = 0.15
				overlay = Color(0, 0, 0, 0.4)
		"frantic":
			var on := _flicker_on(14.0)
			color = FRANTIC_COLOR
			ambient_color = FRANTIC_COLOR
			sun_energy = 0.45 if on else 0.1
			ambient_energy = 0.25 if on else 0.05
			overlay = Color(0.35, 0.0, 0.0, 0.22 if on else 0.45)
		"blackout":
			sun_energy = 0.0
			ambient_energy = 0.0
			overlay = Color(0, 0, 0, 0.88)
	_sun.light_energy = sun_energy
	_sun.light_color = color
	_env.ambient_light_energy = ambient_energy
	_env.ambient_light_color = ambient_color
	_light_overlay.color = overlay


func _flicker_on(speed: float) -> bool:
	return sin(_light_time * speed) * sin(_light_time * speed * 2.3 + 1.0) > -0.35


func _flash() -> void:
	flashes += 1
	_flash_rect.color.a = FLASH_ALPHA
	create_tween().tween_property(_flash_rect, "color:a", 0.0, FLASH_TIME)


# ── The 반주기 panel and the rest of the UI ─────────────────────────────

func _label(text: String, size: int, align := HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_ui() -> void:
	# Under the panel and the options, so the lyrics stay readable in the dark.
	var light_layer := CanvasLayer.new()
	light_layer.layer = 4
	add_child(light_layer)
	_light_overlay = ColorRect.new()
	_light_overlay.color = Color(0, 0, 0, 0)
	_light_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_light_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	light_layer.add_child(_light_overlay)
	var ui := CanvasLayer.new()
	ui.layer = 5
	add_child(ui)
	var panel := Panel.new()
	panel.position = Vector2(210, 800)
	panel.size = Vector2(1500, 240)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.16, 0.95)
	sb.border_color = Color(0.5, 0.7, 1.0)
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(14)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(panel)
	var clip := Control.new()
	clip.name = "LyricClip"
	clip.position = Vector2(30, 20)
	clip.size = CLIP_SIZE
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(clip)
	_lyric_col = Control.new()
	_lyric_col.name = "LyricColumn"
	_lyric_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(_lyric_col)

	_option_box = VBoxContainer.new()
	_option_box.position = Vector2(610, 150)
	_option_box.size = Vector2(700, 240)
	_option_box.add_theme_constant_override("separation", 10)
	_option_box.visible = false
	ui.add_child(_option_box)
	for i in 4:
		var b := Button.new()
		b.custom_minimum_size = Vector2(700, 70)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 40)
		b.mouse_entered.connect(func(): if state == State.FREEZE and options[i] != logic.crossed: _select(i))
		b.pressed.connect(func(): pick(i))
		_option_box.add_child(b)
		_option_buttons.append(b)
		var strike := ColorRect.new()
		strike.name = "Strike"
		strike.color = Color(1.0, 0.35, 0.3)
		strike.mouse_filter = Control.MOUSE_FILTER_IGNORE
		strike.visible = false
		b.add_child(strike)

	_cross_hint = _label("", 26)
	_cross_hint.position = Vector2(210, 1044)
	_cross_hint.size = Vector2(1500, 34)
	_cross_hint.add_theme_color_override("font_color", Color(0.95, 0.9, 0.6))
	_cross_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_cross_hint.add_theme_constant_override("outline_size", 8)
	_cross_hint.visible = false
	ui.add_child(_cross_hint)

	_loaded_label = _label("", 56)
	_loaded_label.position = Vector2(210, 650)
	_loaded_label.size = Vector2(1500, 70)
	_loaded_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	_loaded_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_loaded_label.add_theme_constant_override("outline_size", 14)
	_loaded_label.visible = false
	ui.add_child(_loaded_label)

	_timer_bar_bg = ColorRect.new()
	_timer_bar_bg.color = Color(0, 0, 0, 0.6)
	_timer_bar_bg.position = Vector2(610, 96)
	_timer_bar_bg.size = Vector2(700, 30)
	_timer_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_timer_bar_bg)
	_timer_bar = ColorRect.new()
	_timer_bar.color = Color(1.0, 0.8, 0.2)
	_timer_bar.position = Vector2(614, 100)
	_timer_bar.size = Vector2(692, 22)
	_timer_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_timer_bar)
	_timer_label = _label("5.0", 48)
	_timer_label.position = Vector2(610, 36)
	_timer_label.size = Vector2(700, 60)
	ui.add_child(_timer_label)
	_hide_timer()

	_banner = _label("", 40)
	_banner.position = Vector2(210, 725)
	_banner.size = Vector2(1500, 60)
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 12)
	ui.add_child(_banner)

	_flash_rect = ColorRect.new()
	_flash_rect.color = Color(0.8, 0.0, 0.0, 0.0)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(_flash_rect)

	# Cards go under the HUD (layer 12) so the hearts stay visible.
	_card_layer = CanvasLayer.new()
	_card_layer.layer = 11
	_card_layer.visible = false
	add_child(_card_layer)
	_card_bg = ColorRect.new()
	_card_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_card_layer.add_child(_card_bg)
	_card_splats = Control.new()
	_card_splats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_splats.set_anchors_preset(Control.PRESET_FULL_RECT)
	_card_layer.add_child(_card_splats)
	_card_title = _label("", 84)
	_card_title.position = Vector2(160, 220)
	_card_title.size = Vector2(1600, 120)
	_card_layer.add_child(_card_title)
	_card_body = _label("", 44)
	_card_body.position = Vector2(260, 380)
	_card_body.size = Vector2(1400, 260)
	_card_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_layer.add_child(_card_body)
	_card_score = _label("", 96)
	_card_score.position = Vector2(160, 650)
	_card_score.size = Vector2(1600, 130)
	_card_score.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	_card_layer.add_child(_card_score)
	_card_hint = _label("", 32)
	_card_hint.position = Vector2(160, 900)
	_card_hint.size = Vector2(1600, 50)
	_card_layer.add_child(_card_hint)
	_after_panel = Panel.new()
	_after_panel.position = Vector2(210, 700)
	_after_panel.size = Vector2(1500, 240)
	var after_style := StyleBoxFlat.new()
	after_style.bg_color = Color(0.04, 0.04, 0.06, 0.92)
	after_style.border_color = Color(0.85, 0.8, 0.65)
	after_style.set_border_width_all(3)
	after_style.set_corner_radius_all(10)
	_after_panel.add_theme_stylebox_override("panel", after_style)
	_after_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_after_panel.visible = false
	_card_layer.add_child(_after_panel)
	_after_speaker = _label("", 36, HORIZONTAL_ALIGNMENT_LEFT)
	_after_speaker.position = Vector2(32, 16)
	_after_speaker.size = Vector2(1000, 50)
	_after_speaker.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_after_panel.add_child(_after_speaker)
	_after_text = _label("", 44, HORIZONTAL_ALIGNMENT_LEFT)
	_after_text.position = Vector2(32, 76)
	_after_text.size = Vector2(1436, 110)
	_after_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_after_panel.add_child(_after_text)
	var after_hint := _label("Press Enter", 26, HORIZONTAL_ALIGNMENT_RIGHT)
	after_hint.position = Vector2(1100, 190)
	after_hint.size = Vector2(370, 40)
	_after_panel.add_child(after_hint)
	_retry_button = Button.new()
	_retry_button.text = RETRY_TEXT
	_retry_button.focus_mode = Control.FOCUS_NONE
	_retry_button.add_theme_font_size_override("font_size", 52)
	_retry_button.position = Vector2(710, 720)
	_retry_button.size = Vector2(500, 110)
	_retry_button.visible = false
	_retry_button.pressed.connect(retry)
	_card_layer.add_child(_retry_button)


## Red placeholder carnage on the revenge card (seeded, so the card looks the same each time).
func _scatter_splats() -> void:
	for c in _card_splats.get_children():
		c.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 7
	for i in 46:
		var r := ColorRect.new()
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var s := rng.randf_range(24.0, 150.0)
		r.size = Vector2(s, s * rng.randf_range(0.4, 1.0))
		r.position = Vector2(rng.randf_range(-20, 1900), rng.randf_range(-20, 1040))
		r.rotation = rng.randf_range(0.0, PI)
		r.color = Color(rng.randf_range(0.55, 0.9), 0.0, rng.randf_range(0.0, 0.08), rng.randf_range(0.3, 0.65))
		_card_splats.add_child(r)


func _build_lines() -> void:
	for i in song["lines"].size():
		var l := _label("", 40)
		l.position = Vector2(0, i * LINE_H)
		l.size = Vector2(CLIP_SIZE.x, LINE_H)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_lyric_col.add_child(l)
		_line_labels.append(l)
		_line_texts.append("")


## The line as shown: the blank as `fill` (default "___"), spoken lines with their speaker.
func _display_text(i: int, fill := "___") -> String:
	var line: Dictionary = song["lines"][i]
	var text: String = str(line["text"]).replace("___", fill)
	if line.has("speaker"):
		text = "%s: %s" % [line["speaker"], text]
	return text


func _apply_line_texts() -> void:
	for i in _line_labels.size():
		_line_labels[i].text = _line_texts[i]


func _line_of(blank: Dictionary) -> int:
	for i in song["lines"].size():
		if int(song["lines"][i].get("blank", 0)) == int(blank["n"]):
			return i
	return 0


## Scrolls the lyric column so the line being sung sits on the middle row.
func _update_scroll() -> void:
	var lines: Array = song["lines"]
	var t := clock.get_position()
	var f := 0.0
	for i in lines.size():
		if float(lines[i]["time"]) <= t:
			f = float(i)
			if i + 1 < lines.size():
				var span := float(lines[i + 1]["time"]) - float(lines[i]["time"])
				f += clampf((t - float(lines[i]["time"])) / maxf(span, 0.001), 0.0, 1.0)
	_lyric_col.position.y = LINE_H - f * LINE_H
	for i in _line_labels.size():
		var d := absf(float(i) - f)
		_line_labels[i].modulate = Color(1.0, 0.95, 0.5, 1.0) if d < 0.5 else Color(0.75, 0.8, 0.95, clampf(1.0 - d * 0.5, 0.15, 0.8))
	_apply_line_texts()


func _fill_option_buttons() -> void:
	for i in _option_buttons.size():
		_option_buttons[i].visible = i < options.size()
		_option_buttons[i].disabled = false
		_option_buttons[i].get_node("Strike").visible = false
		if i < options.size():
			_option_buttons[i].text = options[i]
	_paint_options()


## Highlights the selection; after an answer, green for the right one and red for a wrong pick.
func _paint_options(picked := "", answer := "") -> void:
	for i in options.size():
		var b := _option_buttons[i]
		var color := Color(1, 1, 1)
		if logic.crossed != "" and options[i] == logic.crossed:
			color = Color(0.5, 0.5, 0.5)
		elif answer != "":
			if options[i] == answer:
				color = Color(0.5, 1.0, 0.5)
			elif options[i] == picked:
				color = Color(1.0, 0.4, 0.4)
			else:
				color = Color(0.6, 0.6, 0.6)
		elif i == selected:
			color = Color(1.0, 0.9, 0.3)
		b.add_theme_color_override("font_color", color)
		b.add_theme_color_override("font_hover_color", color)
		b.add_theme_color_override("font_pressed_color", color)
		b.add_theme_color_override("font_disabled_color", color)
		b.text = ("> %s" % options[i]) if (i == selected and answer == "") else options[i]


func _update_timer() -> void:
	var frac := freeze_left / float(song["countdown"])
	_timer_bar.size.x = 692.0 * frac
	_timer_bar.color = Color(1.0, 0.8, 0.2).lerp(Color(1.0, 0.2, 0.15), 1.0 - frac)
	_timer_label.text = "%.1f" % freeze_left


func _hide_timer() -> void:
	_timer_bar_bg.visible = false
	_timer_bar.visible = false
	_timer_label.visible = false


## Plays the whole fight with no waiting: each blank is answered right when
## `right_for.call(n)` is true, else wrong. Stops at a result card or the game over.
func run_scripted(right_for: Callable, dt := 0.05) -> void:
	var guard := 0
	while (state == State.PLAYING or state == State.FREEZE or state == State.BEAT) and guard < 100000:
		if state == State.FREEZE:
			if right_for.call(int(logic.current()["n"])):
				pick_right()
			else:
				pick_wrong()
		else:
			step(dt)
		guard += 1

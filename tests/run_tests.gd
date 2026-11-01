# Headless test runner. Exits non-zero on any failure.
#   godot --headless --import            (first time only)
#   godot --headless --path . -s res://tests/run_tests.gd
#
# Expected log noise (these tests deliberately trigger them): one push_error for
# an unknown card id, one for end_fight with a bad outcome, one for retry_fight
# outside a fight, and push_warnings for damage/heal/add_nunchi/spend_nunchi with
# values <= 0.
# The world test with a save from a newer version adds one more push_error
# ("World: could not load the save ...").
# Bad --seed / --hearts / --skip-to / --fight / --fight-auto values push_warnings by design.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
extends SceneTree

const GameStateScript := preload("res://scripts/game_state.gd")
const SAVE_DIR := "user://test_saves"

var failures := 0
var checks := 0


func _initialize() -> void:
	await process_frame
	var real_save := GameStateScript.SAVE_PATH
	var real_existed := FileAccess.file_exists(real_save)
	var real_before := FileAccess.get_file_as_bytes(real_save) if real_existed else PackedByteArray()
	check(_gs().save_path == GameStateScript.SANDBOX_PATH, "the test runner uses the sandbox save path, not the real one")
	_test_hearts()
	_test_nunchi()
	_test_secrets()
	_test_fights()
	_test_resets()
	_test_saves()
	_test_helpers()
	_test_map_day()
	_test_dealer_data()
	_test_dealer()
	_test_reload_sim()
	_test_hud_pure()
	_test_launch_args()
	_test_project()
	await _test_stage()
	_test_movement_pure()
	await _test_player()
	_test_map_graph()
	await _test_map_walk()
	await _test_world_launch()
	_test_dialogue_file()
	_test_script_matches_doc()
	await _test_choice_effects()
	await _test_choice_paths()
	await _test_dialogue_box()
	await _test_hud_cues()
	await _test_scene_flow()
	await _test_days_and_resume()
	await _test_skip_to()
	await _test_hud_icons()
	await _test_world_search()
	await _test_world_full_run()
	_test_3b_files()
	await _test_scene2_effects()
	await _test_scene2_paths()
	await _test_scene2_flow()
	await _test_resume_steps()
	await _test_scene2_death()
	await _test_optional_conversations()
	await _test_polish()
	await _test_keycap()
	_test_door_clearance()
	_test_empty_classroom()
	_test_3c_files()
	_test_import_and_dialogue()
	var project_path := ProjectSettings.globalize_path("res://project.godot")
	var project_before := FileAccess.get_file_as_bytes(project_path)
	_test_song_json()
	_test_song_clock()
	_test_fight_logic()
	await _test_fight_scene()
	await _test_fight_world()
	await _test_build_4b()
	check(FileAccess.get_file_as_bytes(project_path) == project_before, "the fight tests leave project.godot byte-identical")
	check(FileAccess.file_exists(real_save) == real_existed and (not real_existed or FileAccess.get_file_as_bytes(real_save) == real_before), "the real save was never touched by the run")
	_clean_world_saves()
	print("\n%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("  ok   ", label)
	else:
		failures += 1
		print("  FAIL ", label)


func make_gs() -> Node:
	var gs: Node = GameStateScript.new()
	gs.load_data()
	gs.new_game()
	return gs


func same(a: Variant, b: Variant) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


## Counts signal emissions by name.
func watch(gs: Node, names: Array) -> Dictionary:
	var counts := {}
	for n in names:
		counts[n] = 0
		var sig: Signal = gs.get(n)
		sig.connect(func(_a = null, _b = null): counts[n] += 1)
	return counts


# ── Hearts ─────────────────────────────────────────────────────────────

func _test_hearts() -> void:
	print("Hearts")
	var gs := make_gs()
	check(gs.hearts_halves == 10 and gs.hearts_max_halves == 10, "starts at 10 halves (tuning)")
	var c := watch(gs, ["player_died", "fight_lost", "hearts_changed"])
	gs.damage(1)
	check(gs.hearts_halves == 9, "damage counts halves")
	gs.heal(5)
	check(gs.hearts_halves == 10, "heal clamps to max")
	gs.damage(0)
	gs.damage(-3)
	gs.heal(0)
	check(gs.hearts_halves == 10, "damage/heal <= 0 ignored")
	gs.damage(4)
	gs.damage(100)
	check(gs.hearts_halves == 0, "damage clamps at 0")
	check(c["player_died"] == 1 and c["fight_lost"] == 0, "player_died fires once on transition to 0")
	gs.damage(2)
	check(c["player_died"] == 1, "no second player_died when damage lands at 0")
	gs.heal(3)
	gs.damage(3)
	check(c["player_died"] == 2, "fires again after healing and dying again")
	gs.new_game()
	var c2 := watch(gs, ["player_died", "fight_lost"])
	gs.begin_fight("eunju")
	gs.damage(10)
	check(c2["fight_lost"] == 1 and c2["player_died"] == 0, "fight_lost instead of player_died in a fight")
	gs.damage(1)
	check(c2["fight_lost"] == 1, "fight_lost not repeated at 0")
	check(gs.hearts_halves == 0 and gs.in_fight, "GameState never resets itself on death")
	gs.free()


# ── Nunchi ─────────────────────────────────────────────────────────────

func _test_nunchi() -> void:
	print("Nunchi")
	var gs := make_gs()
	check(gs.add_nunchi(3) == 0 and gs.nunchi == 3, "adds below cap, no overflow")
	var over: int = gs.add_nunchi(6)
	check(gs.nunchi == 7 and over == 2, "caps at 7, returns overflow 2")
	check(gs.ddeok == 2, "overflow becomes DDEOK at 1 per point")
	gs.nunchi_overflow_ddeok_per_point = 3
	gs.add_nunchi(2)
	check(gs.ddeok == 8, "overflow uses the tuned rate")
	check(gs.add_nunchi(0) == 0 and gs.nunchi == 7, "add_nunchi(0) ignored")
	check(gs.spend_nunchi(3) and gs.nunchi == 4, "spend_nunchi succeeds when enough")
	check(not gs.spend_nunchi(5) and gs.nunchi == 4, "spend_nunchi fails when short, spends nothing")
	check(not gs.spend_nunchi(0), "spend_nunchi(0) is false")
	gs.add_ddeok(5)
	check(gs.ddeok == 13, "add_ddeok")
	gs.free()


# ── Secrets ────────────────────────────────────────────────────────────

func _test_secrets() -> void:
	print("Secrets")
	var gs := make_gs()
	check(gs.hand.size() == 7 and gs.secrets_held == gs.hand, "starts holding the 7-card Act 1 hand")
	check(gs.has_secret("pride"), "has_secret")
	var lost := watch(gs, ["secret_lost"])
	var got_args := []
	gs.secret_lost.connect(func(card, by): got_args.append([card, by]))
	check(gs.lose_secret("pride", "banjang"), "held card: returns true")
	check(not gs.has_secret("pride") and lost["secret_lost"] == 1, "held card removed, signal emitted")
	check(got_args == [["pride", "banjang"]], "signal carries card and knower")
	check(gs.knows("banjang", "pride"), "explicit knower learns it")

	check(not gs.lose_secret("pride", "banjang") and lost["secret_lost"] == 1, "already-lost: false, no signal")
	check(not gs.lose_secret("pride", "banjang") and gs.secrets_known_by["pride"].size() == 1, "no duplicate knowers")
	gs.lose_secret("pride", "eunju")
	check(gs.knows("eunju", "pride") and lost["secret_lost"] == 1, "already-lost card still taught to a new person, no signal")

	gs.set_boss("teacher")
	gs.lose_secret("our_home")
	check(gs.knows("teacher", "our_home"), "empty 'by' uses current_boss")
	gs.current_boss = ""
	gs.lose_secret("mom_job")
	check(not gs.has_secret("mom_job") and not gs.secrets_known_by.has("mom_job"), "no by, no boss: lost but nobody learns it")
	check(got_args.back() == ["mom_job", ""], "signal still fires with empty knower")

	gs.lose_secret("dad_story", "hyunjeong")
	check(gs.knows("hyunjeong", "dad_story") and gs.knows("hyunjeong_mom", "dad_story"), "one-hop leak: hyunjeong -> hyunjeong_mom")
	gs.leaks["hyunjeong_mom"] = ["hyunjeong_dad"]
	gs.lose_secret("dad_country", "hyunjeong")
	check(not gs.knows("hyunjeong_dad", "dad_country"), "leak is not transitive")
	gs.leaks.erase("hyunjeong_mom")

	check(not gs.lose_secret("not_a_card", "x"), "unknown card id: false")
	check(not gs.secrets_known_by.has("not_a_card"), "unknown card id changes nothing")

	gs.lose_secret("mom_salary", "banjang")
	check(same(gs.cards_known_by("banjang"), ["mom_salary", "pride"]), "cards_known_by in hand order (mom_salary before pride)")
	check(gs.cards_known_by("nobody").is_empty(), "cards_known_by unknown person is empty")
	gs.free()


# ── Fights ─────────────────────────────────────────────────────────────

func _test_fights() -> void:
	print("Fights")
	var gs := make_gs()
	gs.add_nunchi(4)
	gs.damage(3)
	gs.begin_fight("eunju")
	check(gs.in_fight and gs.current_boss == "eunju", "begin_fight sets boss and flag")
	gs.damage(4)
	gs.spend_nunchi(3)
	check(gs.retry_fight(), "retry_fight succeeds in a fight")
	check(gs.hearts_halves == 7 and gs.nunchi == 4, "retry restores hearts and 눈치")
	check(gs.in_fight, "still in fight after retry")
	gs.damage(2)
	gs.end_fight("eunju", "survival", 50)
	check(not gs.in_fight and gs.fight_snapshot.is_empty(), "end_fight clears flag and snapshot")
	check(gs.hearts_halves == 5, "survival restores nothing")
	check(gs.scores["eunju"] == 50 and gs.outcomes["eunju"] == "survival", "records score and outcome")
	gs.end_fight("eunju", "survival", 30)
	check(gs.scores["eunju"] == 50, "scores keeps the best")
	gs.end_fight("eunju", "survival", 80)
	check(gs.scores["eunju"] == 80, "higher score replaces")
	gs.end_fight("eunju", "revenge", 10)
	check(gs.outcomes["eunju"] == "revenge" and gs.scores["eunju"] == 80, "revenge beats survival, score stays best")
	check(gs.hearts_halves == 10, "revenge heals to full")
	gs.end_fight("eunju", "survival", 90)
	check(gs.outcomes["eunju"] == "revenge", "survival never overwrites revenge")
	check(not gs.end_fight("eunju", "draw", 1), "invalid outcome rejected")
	check(gs.scores["eunju"] == 90, "rejected call changed nothing")
	var fresh := make_gs()
	check(not fresh.retry_fight(), "retry_fight outside a fight is rejected")
	fresh.free()
	gs.free()


# ── Resets ─────────────────────────────────────────────────────────────

func _dirty(gs: Node) -> void:
	gs.damage(4)
	gs.add_nunchi(9)
	gs.add_ddeok(3)
	gs.lose_secret("pride", "hyunjeong")
	gs.spawn_seed = 12345
	gs.mark_collected("map1-day2", "coin")
	gs.add_note("n")
	gs.mark_talked("t")
	gs.add_item("i")
	gs.end_fight("eunju", "revenge", 5)
	gs.set_progress("scene_09")
	gs.unlock_codex("c")
	gs.begin_fight("banjang")


func _test_resets() -> void:
	print("Resets")
	var gs := make_gs()
	var defaults: Dictionary = gs._default_state()
	check(defaults.size() == 18, "default state has all 18 saved fields")
	_dirty(gs)
	var died := watch(gs, ["state_reset"])
	gs.death_reset()
	for key in defaults:
		if key == "progress":
			continue
		check(var_to_str(gs.get(key)) == var_to_str(defaults[key]), "death_reset restores %s" % key)
	check(gs.progress == "scene_01", "death_reset progress = scene_01")
	check(died["state_reset"] == 1, "death_reset emits state_reset")
	check(gs.leaks.has("hyunjeong"), "leaks (data) untouched by reset")
	_dirty(gs)
	gs.new_game()
	for key in defaults:
		if key == "progress":
			continue
		check(var_to_str(gs.get(key)) == var_to_str(defaults[key]), "new_game restores %s" % key)
	check(gs.progress == "scene_01", "new_game progress = scene_01")
	check(GameStateScript.PERSISTS_THROUGH_DEATH.is_empty(), "PERSISTS_THROUGH_DEATH is empty for now")
	_dirty(gs)
	gs._death_reset_keeping(["ddeok", "notes", "scores"] as Array[String])
	check(gs.ddeok == 5 and same(gs.notes, ["n"]) and gs.scores.has("eunju"), "listed fields survive the reset")
	check(gs.nunchi == 0 and gs.hearts_halves == 10 and gs.progress == "scene_01", "unlisted fields still reset")
	gs.free()


# ── Saves ──────────────────────────────────────────────────────────────

func _clean_saves() -> void:
	var dir := DirAccess.open(SAVE_DIR)
	if dir:
		for f in dir.get_files():
			dir.remove(f)
		DirAccess.remove_absolute(SAVE_DIR)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _state_str(gs: Node) -> String:
	return JSON.stringify(gs._current_state(), "", true)


func _test_saves() -> void:
	print("Saves")
	_clean_saves()
	var gs := make_gs()
	gs.save_path = SAVE_DIR + "/save.json"
	check(not gs.has_save(), "has_save false before saving")
	check(gs.load_game() == ERR_FILE_NOT_FOUND, "load with no file -> ERR_FILE_NOT_FOUND")

	_dirty(gs)
	var before := _state_str(gs)
	check(gs.save_game() == OK and gs.has_save(), "save_game OK")
	check(not FileAccess.file_exists(gs.save_path + ".tmp"), "atomic write leaves no temp file")
	check(not FileAccess.file_exists(gs.save_path + ".bak"), "no .bak on first save")
	var env = JSON.parse_string(_read(gs.save_path))
	check(env["game"] == "noraebang-night" and int(env["save_version"]) == 1 and env["state_version"] == "0.4", "envelope fields")
	check(not env["state"].has("leaks"), "leaks are not saved")

	var other := make_gs()
	other.save_path = gs.save_path
	check(other.load_game() == OK, "load_game OK")
	check(_state_str(other) == before, "round-trip equality")
	check(other.leaks.has("hyunjeong"), "leaks come from data after load")

	gs.add_ddeok(1)
	var second := _state_str(gs)
	gs.save_game()
	check(FileAccess.file_exists(gs.save_path + ".bak"), ".bak created on second save")
	check(not FileAccess.file_exists(gs.save_path + ".tmp"), "still no temp file")
	var bak = JSON.parse_string(_read(gs.save_path + ".bak"))
	check(int(bak["state"]["ddeok"]) == 5, ".bak holds the previous save")

	# Corrupt main -> falls back to .bak.
	_write(gs.save_path, "{ not json")
	var fallback := make_gs()
	fallback.save_path = gs.save_path
	check(fallback.load_game() == OK and fallback.ddeok == 5, "corrupt JSON falls back to .bak")

	# Both corrupt -> error, state untouched.
	_write(gs.save_path + ".bak", "garbage")
	var untouched := make_gs()
	untouched.save_path = gs.save_path
	untouched.add_ddeok(42)
	var snap := _state_str(untouched)
	check(untouched.load_game() == ERR_FILE_CORRUPT, "both corrupt -> ERR_FILE_CORRUPT")
	check(_state_str(untouched) == snap, "state untouched after failed load")

	# Future version rejected, file untouched.
	var future := JSON.stringify({"game": "noraebang-night", "save_version": 99, "state_version": "9.9", "state": {"ddeok": 5}})
	_write(gs.save_path, future)
	check(untouched.load_game() == ERR_UNAVAILABLE, "future save_version -> ERR_UNAVAILABLE")
	check(_read(gs.save_path) == future and _state_str(untouched) == snap, "future file and state left unchanged")

	# Version 0: bare state dictionary.
	_write(gs.save_path, JSON.stringify({"ddeok": 9, "nunchi": 2, "progress": "scene_03", "hearts_halves": 6}))
	var v0 := make_gs()
	v0.save_path = gs.save_path
	check(v0.load_game() == OK, "version-0 bare dict loads")
	check(v0.ddeok == 9 and v0.nunchi == 2 and v0.progress == "scene_03" and v0.hearts_halves == 6, "version-0 values migrated")
	check(v0.secrets_held == v0.hand, "version-0 missing keys take defaults")
	check(v0._migrate_0_to_1({"a": 1}) == {"a": 1}, "_migrate_0_to_1 exists")

	# Normalisation.
	var messy := {
		"game": "noraebang-night", "save_version": 1, "state_version": "0.4",
		"state": {
			"hearts_halves": 99, "nunchi": -4, "ddeok": -1, "spawn_seed": "x",
			"secrets_held": ["pride", "pride", "bogus", 7, "our_home"],
			"secrets_known_by": {"pride": ["a", "a", 3, "b"], "bogus": ["z"], "our_home": "nope"},
			"notes": ["n", "n", 1], "talked": "oops", "scores": {"eunju": 12.0, "x": "bad"},
			"outcomes": {"eunju": "revenge", "x": "other"}, "progress": 5,
			"in_fight": true, "fight_snapshot": {}, "unknown_key": 1, "leaks": {"a": ["b"]},
			"collected": {"m-1": ["c", "c"]},
		},
	}
	_write(gs.save_path, JSON.stringify(messy))
	var norm := make_gs()
	norm.save_path = gs.save_path
	check(norm.load_game() == OK, "messy save loads")
	check(norm.hearts_halves == 10 and norm.nunchi == 0 and norm.ddeok == 0, "out-of-range numbers clamped")
	check(norm.spawn_seed == 0 and norm.progress == "", "wrong types fall back to defaults")
	check(same(norm.secrets_held, ["pride", "our_home"]), "secrets_held deduped, unknown/non-string dropped")
	check(norm.secrets_known_by == {"pride": ["a", "b"]}, "secrets_known_by cleaned")
	check(same(norm.notes, ["n"]) and norm.talked.is_empty(), "string arrays deduped / type-checked")
	check(norm.scores == {"eunju": 12} and norm.outcomes == {"eunju": "revenge"}, "scores and outcomes cleaned")
	check(not norm.in_fight, "in_fight without a snapshot is dropped")
	check(norm.collected == {"m-1": ["c"]}, "collected deduped")
	check(not ("unknown_key" in norm._current_state()) and norm.leaks.has("hyunjeong") and not norm.leaks.has("a"), "unknown keys dropped, saved leaks ignored")

	gs.free(); other.free(); fallback.free(); untouched.free(); v0.free(); norm.free()
	_clean_saves()
	check(not DirAccess.dir_exists_absolute(SAVE_DIR), "test saves cleaned up")


func _test_helpers() -> void:
	print("Helpers")
	var gs := make_gs()
	gs.add_note("a"); gs.add_note("a")
	check(gs.has_note("a") and gs.notes.size() == 1, "notes")
	gs.mark_talked("x")
	check(gs.has_talked("x") and not gs.has_talked("y"), "talked")
	gs.add_item("red_medicine")
	check(gs.owns_item("red_medicine") and not gs.owns_item("bandage"), "items")
	gs.mark_collected("m1-d1", "k"); gs.mark_collected("m1-d1", "k")
	check(gs.is_collected("m1-d1", "k") and not gs.is_collected("m1-d2", "k") and gs.collected["m1-d1"].size() == 1, "collected")
	gs.unlock_codex("c"); gs.unlock_codex("c")
	check(same(gs.codex, ["c"]), "codex")
	gs.set_progress("scene_05")
	check(gs.progress == "scene_05", "set_progress")
	gs.free()


# ── Project ────────────────────────────────────────────────────────────

func _action_keys(action: String) -> Array:
	var keys := []
	for e in InputMap.action_get_events(action):
		if e is InputEventKey:
			keys.append(e.physical_keycode if e.physical_keycode != KEY_NONE else e.keycode)
	return keys


func _scan(dir: String, needles: Array, hits: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() in ["ttf", "png", "import", "uid", "ogg", "wav", "mp3"] or f == "run_tests.gd":
			continue
		var text := FileAccess.get_file_as_string(dir.path_join(f))
		for n in needles:
			if text.contains(n):
				hits.append("%s contains %s" % [dir.path_join(f), n])
	for d in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(d), needles, hits)


func _test_project() -> void:
	print("Project")
	check(ProjectSettings.get_setting("rendering/renderer/rendering_method") == "forward_plus", "renderer setting is forward_plus")
	check(ProjectSettings.get_setting("display/window/size/viewport_width") == 1920 and ProjectSettings.get_setting("display/window/size/viewport_height") == 1080, "viewport 1920x1080")
	check(ProjectSettings.get_setting("display/window/stretch/mode") == "canvas_items" and ProjectSettings.get_setting("display/window/stretch/aspect") == "keep", "stretch canvas_items / keep")
	var features: PackedStringArray = ProjectSettings.get_setting("application/config/features")
	check(features.has("4.7") and features.has("Forward Plus"), "config/features has 4.7 and Forward Plus")
	var v := Engine.get_version_info()
	print("  engine: %s" % Engine.get_version_info()["string"])
	check(v["major"] == 4 and v["minor"] == 7, "Engine is 4.7.x (patch %d)" % v["patch"])

	var expect := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"confirm": [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE],
	}
	for action in expect:
		check(InputMap.has_action(action) and _action_keys(action) == expect[action], "input action %s = %s" % [action, expect[action]])
	var up := _action_keys("ui_up")
	var down := _action_keys("ui_down")
	check(up.has(KEY_UP) and up.has(KEY_W), "ui_up has Up and W")
	check(down.has(KEY_DOWN) and down.has(KEY_S), "ui_down has Down and S")
	check(InputMap.action_get_events("ui_up").size() >= 4, "ui_up keeps its joypad defaults")
	var accept := _action_keys("ui_accept")
	check(accept.has(KEY_ENTER) and accept.has(KEY_KP_ENTER) and accept.has(KEY_SPACE), "ui_accept still accepts Enter and Space")
	var press := InputEventKey.new()
	press.keycode = KEY_ENTER
	press.pressed = true
	check(InputMap.event_is_action(press, "ui_accept"), "an Enter key event matches ui_accept")

	check(ProjectSettings.get_setting("gui/theme/custom") == "res://themes/main_theme.tres", "project theme is set")
	var theme := ThemeDB.get_project_theme()
	check(theme != null and theme.default_font != null, "project theme has a default font")
	if theme != null and theme.default_font != null:
		print("  default font name: %s" % theme.default_font.get_font_name())
		check(theme.default_font.resource_path.contains("NotoSansKR") and theme.default_font.get_font_name().contains("Noto Sans"), "default font is Noto Sans KR")

	var hits := []
	var needles := ["Gal" + "muri", "res://" + "legacy"]
	for d in ["res://scenes", "res://scripts", "res://tests", "res://data", "res://themes", "res://art"]:
		_scan(d, needles, hits)
	var proj := FileAccess.get_file_as_string("res://project.godot")
	for n in needles:
		if proj.contains(n):
			hits.append("project.godot contains %s" % n)
	check(hits.is_empty(), "no active file references Galmuri or res://legacy " + str(hits))
	check(FileAccess.file_exists("res://legacy/.gdignore"), "legacy/.gdignore exists")
	check(FileAccess.file_exists("res://docs/.gdignore"), "docs/.gdignore exists")
	check(not DirAccess.dir_exists_absolute("res://art/fonts/Galmuri"), "no Galmuri font dir in active art")


func _test_stage() -> void:
	print("Test stage")
	var packed: PackedScene = load("res://scenes/test_stage.tscn")
	check(packed != null, "test_stage.tscn loads")
	if packed == null:
		return
	var stage := packed.instantiate()
	root.add_child(stage)
	await process_frame
	check(ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/map_01.tscn", "Map 01 is the main scene")
	check(stage.find_children("*", "Camera3D", true, false).size() == 1, "exactly one Camera3D")
	check(stage.find_children("*", "Light3D", true, false).size() == 1, "exactly one light")
	var envs := stage.find_children("*", "WorldEnvironment", true, false)
	check(envs.size() == 1, "exactly one WorldEnvironment")
	if envs.size() == 1:
		var e: Environment = envs[0].environment
		check(e.fog_enabled and e.volumetric_fog_enabled, "fog and volumetric fog enabled")
	var capsules := stage.find_children("*", "MeshInstance3D", true, false).filter(func(m): return m.mesh is CapsuleMesh)
	check(capsules.size() == 1, "a capsule (보람)")
	var lights := stage.find_children("*", "Light3D", true, false)
	check(lights[0].shadow_enabled and lights[0].light_volumetric_fog_energy > 0.0, "light has shadows and volumetric energy")
	stage.queue_free()


# ── Walking (Step 2a) ──────────────────────────────────────────────────

const PlayerScene := preload("res://characters/player.tscn")
const PlayerScript := preload("res://scripts/player.gd")
const MAP_DATA := "res://data/maps/map_01.json"


func _frames(n: int) -> void:
	for i in n:
		await physics_frame
	await process_frame


func _press(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	Input.parse_input_event(e)
	await _frames(2)
	var r := InputEventAction.new()
	r.action = action
	r.pressed = false
	Input.parse_input_event(r)
	await _frames(1)


func _test_movement_pure() -> void:
	print("Lanes (pure)")
	check(PlayerScript.clamp_lane(-1, 3) == 0 and PlayerScript.clamp_lane(0, 3) == 0, "clamp_lane floor")
	check(PlayerScript.clamp_lane(3, 3) == 2 and PlayerScript.clamp_lane(2, 3) == 2, "clamp_lane ceiling")
	check(PlayerScript.clamp_lane(5, 1) == 0, "single lane always 0")
	check(PlayerScript.stepped_lane(0, 1, 3) == 1 and PlayerScript.stepped_lane(1, 1, 3) == 2, "step deeper")
	check(PlayerScript.stepped_lane(2, 1, 3) == 2, "stepping deeper at the last lane stays")
	check(PlayerScript.stepped_lane(0, -1, 3) == 0, "stepping nearer at lane 0 stays")
	check(PlayerScript.stepped_lane(2, -1, 3) == 1, "step nearer")
	var cfg: Dictionary = preload("res://scripts/tuning.gd").lane_config()
	check(cfg["lane_count"] == 3 and is_equal_approx(cfg["lane_spacing"], 1.5), "tuning.json: 3 lanes, spacing 1.5")


func _test_player() -> void:
	print("Player")
	var room: Node3D = load("res://maps/map_01/hallway_1f.tscn").instantiate()
	root.add_child(room)
	var p: Node3D = PlayerScene.instantiate()
	root.add_child(p)
	p.configure_room(room)
	p.place(0.0, 0)
	check(is_equal_approx(p.position.z, room.lane_origin_z), "lane 0 at the room's lane origin")
	check(is_equal_approx(p.lane_z(1), room.lane_origin_z - 1.5), "lane 1 is one spacing deeper")
	p.walk(1.0, 1.0)
	check(is_equal_approx(p.position.x, p.walk_speed), "walk moves along x")
	p.walk(1.0, 100.0)
	check(is_equal_approx(p.position.x, room.bounds_right), "walk clamps at the right bound")
	p.walk(-1.0, 100.0)
	check(is_equal_approx(p.position.x, room.bounds_left), "walk clamps at the left bound")

	p.place(0.0, 0)
	p.step_lane(1)
	p.step_lane(1)
	p.step_lane(1)
	check(p.lane == 2, "lane steps clamp at the deepest lane")
	await _frames(40)
	check(is_equal_approx(p.position.z, p.lane_z(2)), "lane change is smooth and arrives")

	p.movement_locked = true
	var x0: float = p.position.x
	var lane0: int = p.lane
	p.walk(1.0, 1.0)
	p.step_lane(-1)
	check(p.position.x == x0 and p.lane == lane0, "movement_locked blocks walk and lane steps")
	Input.action_press("move_right")
	await _frames(4)
	check(p.position.x == x0, "movement_locked blocks real input")
	p.movement_locked = false
	await _frames(4)
	check(p.position.x > x0, "unlocked: held D moves the player")
	Input.action_release("move_right")
	await _press("move_down")
	check(p.lane == 1, "pressing S steps one lane nearer")
	await _press("move_up")
	check(p.lane == 2, "pressing W steps one lane deeper")
	p.queue_free()
	room.queue_free()
	await _frames(1)


func _door_list(room: Node) -> Array:
	return room.get_children().filter(func(c): return c.has_method("is_door"))


func _test_map_graph() -> void:
	print("Map graph")
	var data = JSON.parse_string(FileAccess.get_file_as_string(MAP_DATA))
	var rooms: Dictionary = data["rooms"]
	check(rooms.size() == 13, "13 rooms registered")
	var scenes := {}
	for id in rooms:
		var packed = load(rooms[id])
		check(packed != null, "room scene loads: %s" % id)
		if packed != null:
			scenes[id] = packed.instantiate()
	check(rooms.has(data["start_room"]) and scenes[data["start_room"]].get_spawn(data["start_spawn"]) != null, "start room and spawn exist")
	var locked := []
	for id in scenes:
		var r: Node = scenes[id]
		check(r.room_id == id, "%s: room_id matches registry" % id)
		check(r.bounds_left < r.bounds_right, "%s: bounds are ordered" % id)
		for d in _door_list(r):
			var tag := "%s -> %s" % [id, d.target_room]
			check(scenes.has(d.target_room), "%s: target room exists" % tag)
			if not scenes.has(d.target_room):
				continue
			var target: Node = scenes[d.target_room]
			var spawn: Node3D = target.get_spawn(d.target_spawn)
			check(spawn != null, "%s: spawn '%s' exists" % [tag, d.target_spawn])
			if spawn != null:
				check(spawn.position.x >= target.bounds_left and spawn.position.x <= target.bounds_right, "%s: spawn is inside bounds" % tag)
			if d.locked:
				locked.append(tag)
			else:
				var back := _door_list(target).filter(func(t): return t.target_room == id)
				check(not back.is_empty(), "%s: has a return door" % tag)
	locked.sort()
	check(locked == ["alley -> alley", "alley -> stationery", "stairs -> hallway_2f"], "locked doors: 2층 복도, 문방구 and the 집 exit (%s)" % str(locked))
	var classroom: Node = scenes["classroom_1_3"]
	var things := classroom.get_children().filter(func(c): return c.has_method("interact") and not c.has_method("is_door"))
	check(things.size() >= 2, "1학년 3반 has %d sample interactables" % things.size())
	for s in scenes.values():
		s.free()


func _wait_transition(world: Node) -> void:
	var guard := 0
	while world.transitioning and guard < 120:
		guard += 1
		await process_frame
	await _frames(2)


func _confirm_at(world: Node, door: Node3D) -> void:
	world.player.place(door.position.x, 0)
	await _frames(3)
	await _press("confirm")
	await _wait_transition(world)


func _explore(world: Node, visited: Dictionary) -> void:
	var here: String = world.room_id
	visited[here] = true
	var descriptors := []
	for d in _door_list(world.room):
		descriptors.append({"name": d.name, "target": d.target_room, "locked": d.locked})
	for desc in descriptors:
		var door: Node3D = world.room.get_node(NodePath(desc["name"]))
		var tag := "%s -> %s" % [here, desc["target"]]
		if desc["locked"]:
			world.player.place(door.position.x, 0)
			await _frames(3)
			check(world.player.current_interactable == door, "%s: prompt target is the locked door" % tag)
			await _press("confirm")
			check(world.room_id == here and world._text_open and world.player.movement_locked, "%s: locked door shows a message and stays" % tag)
			await _press("confirm")
			check(not world._text_open and not world.player.movement_locked, "%s: message closes" % tag)
			continue
		if visited.has(desc["target"]):
			continue
		await _confirm_at(world, door)
		check(world.room_id == desc["target"], "walked %s" % tag)
		if world.room_id != desc["target"]:
			return
		# Arriving puts the player at the return door.
		await _frames(3)
		var arrived = world.player.current_interactable
		check(arrived != null and arrived.has_method("is_door") and arrived.target_room == here, "%s: arrives at the return door" % tag)
		await _explore(world, visited)
		var back: Array = _door_list(world.room).filter(func(t): return t.target_room == here)
		world.player.place(back[0].position.x, 0)
		await _frames(3)
		await _press("confirm")
		await _wait_transition(world)
		check(world.room_id == here, "returned %s <- %s" % [here, desc["target"]])
		if world.room_id != here:
			return


func _test_map_walk() -> void:
	print("Map walk (simulated input)")
	var world: Node = await _start_world()
	check(world.room_id == "hallway_1f", "starts in 1층 복도")
	check(world.player.position.x == -3.0, "starts at the 'start' spawn")

	# Camera follows the player but stays inside the room.
	world.player.place(-18.0, 0)
	world.room.update_camera()
	check(is_equal_approx(world.room.camera.position.x, world.room.bounds_left - 1.0 + 9.0), "camera stops at the left edge")
	world.player.place(5.0, 0)
	world.room.update_camera()
	check(is_equal_approx(world.room.camera.position.x, 5.0), "camera follows the player inside the room")
	world.player.place(-3.0, 0)

	# Sample interactable: shows placeholder text, locks movement, then closes.
	await _confirm_at(world, world.room.get_node("To_classroom_1_3"))
	check(world.room_id == "classroom_1_3", "entered 1학년 3반")
	var stove: Node3D = world.room.get_node("Stove")
	world.player.place(stove.position.x, 0)
	await _frames(3)
	check(world.player.current_interactable == stove, "prompt appears at the stove")
	check(world.key_prompt.visible and world.key_prompt.get_node("KeyText").text == "Enter", "the keycap says Enter")
	world.layout = {}
	await _press("confirm")
	check(world._text_open and world._text_label.text == world.spawn_config["lines"]["empty"] and world.player.movement_locked, "stove (a search spot) shows its search result")
	check(not world.key_prompt.visible, "keycap hidden while text is open")
	await _press("confirm")
	check(not world._text_open and not world.player.movement_locked, "text closes, movement unlocked")
	world.player.place(-4.5, 0)
	await _frames(3)
	check(world.player.current_interactable == null and not world.key_prompt.visible, "no keycap away from anything")
	await _confirm_at(world, world.room.get_node("To_hallway_1f"))
	check(world.room_id == "hallway_1f", "back to 1층 복도")

	var visited := {}
	await _explore(world, visited)
	var ids := visited.keys()
	ids.sort()
	check(ids.size() == 10, "walked through every unlocked room (%d): %s" % [ids.size(), str(ids)])
	check(not visited.has("hallway_2f") and not visited.has("stationery"), "locked rooms stay out of reach")
	world.queue_free()
	await _frames(2)


# ── Step 2b: finding things ────────────────────────────────────────────

const DealerScript := preload("res://scripts/spawn_dealer.gd")
const HeartsScript := preload("res://scripts/hearts_display.gd")
const EyesScript := preload("res://scripts/nunchi_display.gd")
const DdeokIconScript := preload("res://scripts/ddeok_icon.gd")
const WORLD_SAVE_DIR := "user://test_world_saves"
const MAP_KEY := "map_01:sat"


func _gs() -> Node:
	return root.get_node("GameState")


func _clean_world_saves() -> void:
	var dir := DirAccess.open(WORLD_SAVE_DIR)
	if dir:
		for f in dir.get_files():
			dir.remove(f)
		DirAccess.remove_absolute(WORLD_SAVE_DIR)


## A fresh map world on the autoload GameState, saving into the test folder only.
## `with_scene` runs the real start (Scene 01 or the saved progress step); off, the
## world is just the map, starting in the start room.
func _start_world(keep_save := false, with_scene := false) -> Node:
	if not keep_save:
		_clean_world_saves()
	_gs().save_path = WORLD_SAVE_DIR + "/save.json"
	var world: Node = load("res://scenes/map_01.tscn").instantiate()
	world.begin_progress = with_scene
	world.director_time_scale = 40.0
	root.add_child(world)
	world.fade_time = 0.0
	await _frames(3)
	return world


func _stop_world(world: Node) -> void:
	world.queue_free()
	await _frames(2)


func _kind_counts(layout: Dictionary) -> Dictionary:
	var c := {"ddeok": 0, "note": 0, "health": 0, "trap": 0}
	for id in layout:
		c[layout[id]["kind"]] += 1
	return c


func _spot_node(room: Node, spot_id: String) -> Node3D:
	for it in room.find_children("*", "Area3D", true, false):
		if it.get("spot_id") == spot_id:
			return it
	return null


## Walks the player to a spot (loading its room directly) and presses Enter.
func _search_spot(world: Node, config: Dictionary, spot_id: String) -> bool:
	var room_id: String = config["spots"][spot_id]["room"]
	if world.room_id != room_id:
		world._load_room(room_id, "")
	var node := _spot_node(world.room, spot_id)
	world.player.place(node.position.x, 0)
	await _frames(3)
	var reachable: bool = world.player.current_interactable == node
	await _press("confirm")
	return reachable


func _close_text(world: Node) -> void:
	if world._text_open:
		await _press("confirm")


func _test_map_day() -> void:
	print("map_day")
	var gs := make_gs()
	check(gs.map_day == "sat", "map_day defaults to sat")
	gs.map_day = "mon"
	gs.death_reset()
	check(gs.map_day == "sat", "death_reset puts the day back to sat")
	gs.map_day = "mon"
	_clean_saves()
	gs.save_path = SAVE_DIR + "/day.json"
	gs.save_game()
	var other := make_gs()
	other.save_path = gs.save_path
	other.load_game()
	check(other.map_day == "mon", "map_day survives a save round trip")
	check(gs._normalize({"map_day": 7}).map_day == "sat" and gs._normalize({"map_day": ""}).map_day == "sat", "bad map_day falls back to sat")
	check(gs._normalize({}).map_day == "sat", "missing map_day (older save) loads as sat")
	_clean_saves()
	gs.free()
	other.free()


func _test_dealer_data() -> void:
	print("Spawn data")
	var cfg: Dictionary = DealerScript.load_config()
	check(not cfg.is_empty(), "spawn config loads")
	var spots: Dictionary = cfg["spots"]
	check(spots.size() == 12, "12 spots")
	check(cfg["budgets"].keys().size() == 2 and cfg["budgets"].has("sat") and cfg["budgets"].has("mon"), "budgets for sat and mon")
	for day in ["sat", "mon"]:
		var b: Dictionary = cfg["budgets"][day]
		check(b["ddeok"] == 2 and b["ddeok_amount"] == 1 and b["extras"] == 1 and b["traps"] == 2, "%s budget: 2 DDEOK (1 each), 1 extra, 2 traps" % day)
		check(b["ddeok"] + b["extras"] == 3 and b["traps"] == 2, "%s: 3 rewards to 2 traps (6:4)" % day)
	check(cfg["extras"]["note"]["weight"] == 2 and cfg["extras"]["band_aid"]["weight"] == 2 and cfg["extras"]["red_medicine"]["weight"] == 1, "extra weights 2 / 2 / 1")
	check(cfg["extras"]["band_aid"]["heal"] == 1 and cfg["extras"]["red_medicine"]["heal"] == 2, "반창고 heals 1 half, 빨간약 heals 2")
	check(cfg["notes"].size() == 3, "3 notes")
	var all_placeholder := true
	for id in cfg["notes"]:
		all_placeholder = all_placeholder and cfg["notes"][id].contains("[placeholder]")
	for k in cfg["lines"]:
		all_placeholder = all_placeholder and cfg["lines"][k].contains("[placeholder]")
	check(all_placeholder, "every note and narration line is marked [placeholder]")
	var half_spots := []
	var every_trap := true
	for id in spots:
		var spot: Dictionary = spots[id]
		every_trap = every_trap and spot.has("trap") and int(spot["trap"]["damage"]) in [1, 2] and int(spot["trap"]["weight"]) >= 1
		if spot["trap"]["damage"] == 1:
			half_spots.append(id)
	check(every_trap, "every spot has a trap with damage 1 or 2 halves and a weight")
	half_spots.sort()
	check(half_spots == ["back_chair", "cabinet", "lectern", "shoe_rack"], "½-heart traps: 교탁, chair, 청소도구함, 신발장 (%s)" % str(half_spots))
	check(spots["landing_2f"]["days"] == ["mon"], "2층 landing is Monday only")
	var sat_spots := spots.keys().filter(func(id): return spots[id]["days"].has("sat"))
	check(sat_spots.size() == 10 and spots["behind_radio_shop"]["days"] == ["mon"], "10 spots are eligible on Saturday (전파사 뒤 is Monday only)")
	# Every spot has exactly one gray prop in the named room, and no other room claims it.
	var found := {}
	var rooms: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP_DATA))["rooms"]
	for room_id in rooms:
		var room: Node = load(rooms[room_id]).instantiate()
		for it in room.find_children("*", "Area3D", true, false):
			var sid = it.get("spot_id")
			if typeof(sid) == TYPE_STRING and sid != "":
				found[sid] = found.get(sid, 0) + 1
				check(spots.has(sid) and spots[sid]["room"] == room_id, "spot '%s' sits in its room (%s)" % [sid, room_id])
		room.free()
	var once := true
	for id in spots:
		once = once and found.get(id, 0) == 1
	check(once and found.size() == 12, "each of the 12 spots has exactly one prop")


func _test_dealer() -> void:
	print("Dealer")
	var cfg: Dictionary = DealerScript.load_config()
	var spots: Dictionary = cfg["spots"]
	var counts_ok := {"sat": true, "mon": true}
	var eligible_ok := true
	var no_landing_sat := true
	var deterministic := true
	var layouts := {}
	var half := 0
	var traps := 0
	var seeds := 2000
	for day in ["sat", "mon"]:
		var day_budget: Dictionary = cfg["budgets"][day]
		for s in seeds:
			var l: Dictionary = DealerScript.deal(spots, day_budget, cfg["extras"], s, [], [], day)
			var c := _kind_counts(l)
			counts_ok[day] = counts_ok[day] and c["ddeok"] == 2 and c["note"] + c["health"] == 1 and c["trap"] == 2 and l.size() == 5
			for id in l:
				eligible_ok = eligible_ok and spots.has(id) and spots[id]["days"].has(day)
				if l[id]["kind"] == "trap":
					traps += 1
					half += 1 if l[id]["damage"] == 1 else 0
					# The trap dealt is the spot's own.
					eligible_ok = eligible_ok and l[id]["name"] == spots[id]["trap"]["name"]
				if l[id]["kind"] == "ddeok":
					eligible_ok = eligible_ok and l[id]["amount"] == 1
			if day == "sat":
				no_landing_sat = no_landing_sat and not l.has("landing_2f")
			if s < 200:
				deterministic = deterministic and same(l, DealerScript.deal(spots, day_budget, cfg["extras"], s, [], [], day))
				if day == "sat":
					layouts[JSON.stringify(l)] = true
	check(counts_ok["sat"] and counts_ok["mon"], "budget counts are exact over %d seeds per day (2 DDEOK, 1 extra, 2 traps, 5 spots)" % seeds)
	check(eligible_ok, "only eligible spots are dealt, with their own trap")
	check(no_landing_sat, "the 2층 landing is never dealt on Saturday")
	check(deterministic, "the same seed gives the same layout")
	check(layouts.size() >= 190, "different seeds give different layouts (%d distinct of 200)" % layouts.size())
	var share := float(half) / float(traps)
	check(share > 0.76 and share < 0.84, "about 80%% of dealt traps are ½-heart (%.3f of %d)" % [share, traps])

	# Owned notes are never dealt; with none left a health item takes the slot.
	var b: Dictionary = cfg["budgets"]["sat"]
	var leaked := false
	var notes_dealt := 0
	var all_owned_ok := true
	for s in 1500:
		var l: Dictionary = DealerScript.deal(spots, b, cfg["extras"], s, [], ["note_1", "note_2"], "sat")
		for id in l:
			if l[id]["kind"] == "note":
				notes_dealt += 1
				leaked = leaked or l[id]["note_id"] != "note_3"
		var all_l: Dictionary = DealerScript.deal(spots, b, cfg["extras"], s, [], ["note_1", "note_2", "note_3"], "sat")
		var c := _kind_counts(all_l)
		all_owned_ok = all_owned_ok and c["note"] == 0 and c["health"] == 1 and c["ddeok"] == 2 and c["trap"] == 2
	check(notes_dealt > 100 and not leaked, "owned notes are never dealt; only note_3 appears (%d dealt)" % notes_dealt)
	check(all_owned_ok, "with every note owned, the extra becomes a health item")

	# Entries in `collected` shrink the pool and the budget (empties only shrink the pool).
	var prior := ["stove:ddeok", "lectern:trap", "office:empty"]
	var ok := true
	for s in 500:
		var l: Dictionary = DealerScript.deal(spots, b, cfg["extras"], s, prior, [], "sat")
		var c := _kind_counts(l)
		ok = ok and c["ddeok"] == 1 and c["trap"] == 1 and c["note"] + c["health"] == 1
		ok = ok and not l.has("stove") and not l.has("lectern") and not l.has("office")
	check(ok, "remaining budget = budget - taken; searched spots (even empty ones) are not dealt again")
	var spent := ["stove:ddeok", "office:ddeok", "lectern:trap", "cabinet:trap", "shoe_rack:note"]
	check(DealerScript.deal(spots, b, cfg["extras"], 1, spent, [], "sat").is_empty(), "a spent budget deals nothing")


func _test_reload_sim() -> void:
	print("Reload simulation")
	var cfg: Dictionary = DealerScript.load_config()
	var spots: Dictionary = cfg["spots"]
	var b: Dictionary = cfg["budgets"]["sat"]
	var eligible: Array = spots.keys().filter(func(id): return spots[id]["days"].has("sat"))
	eligible.sort()
	_clean_saves()
	var stays := true
	var adds_up := true
	var changed := 0
	var trials := 60
	for t in trials:
		var gs := make_gs()
		gs.save_path = SAVE_DIR + "/reload.json"
		gs.spawn_seed = 100 + t
		var first: Dictionary = DealerScript.deal(spots, b, cfg["extras"], gs.spawn_seed, [], gs.notes, "sat")
		var taken_ids: Array = eligible.slice(0, 3 + t % 6)
		for id in taken_ids:
			var entry: Dictionary = first.get(id, {"kind": "empty"})
			gs.mark_collected(MAP_KEY, "%s:%s" % [id, entry["kind"]])
			if entry["kind"] == "note":
				gs.add_note(entry["note_id"])
		gs.save_game()
		var loaded := make_gs()
		loaded.save_path = gs.save_path
		loaded.load_game()
		loaded.spawn_seed = 9000 + t
		var second: Dictionary = DealerScript.deal(spots, b, cfg["extras"], loaded.spawn_seed, loaded.collected.get(MAP_KEY, []), loaded.notes, "sat")
		for id in taken_ids:
			stays = stays and not second.has(id)
		# taken + remaining = budget, per kind
		var taken_counts := {"ddeok": 0, "extra": 0, "trap": 0}
		for entry in loaded.collected.get(MAP_KEY, []):
			match str(entry).split(":")[1]:
				"ddeok":
					taken_counts["ddeok"] += 1
				"note", "health":
					taken_counts["extra"] += 1
				"trap":
					taken_counts["trap"] += 1
		var left := _kind_counts(second)
		adds_up = adds_up and taken_counts["ddeok"] + left["ddeok"] == b["ddeok"] \
				and taken_counts["extra"] + left["note"] + left["health"] == b["extras"] \
				and taken_counts["trap"] + left["trap"] == b["traps"]
		var first_rest := first.duplicate()
		for id in taken_ids:
			first_rest.erase(id)
		if not same(first_rest, second):
			changed += 1
		gs.free()
		loaded.free()
	_clean_saves()
	check(stays, "collected spots are never dealt again after a reload")
	check(adds_up, "taken + remaining equals the budget after a reload")
	check(changed >= trials * 0.7, "uncollected positions change with the new seed (%d of %d)" % [changed, trials])


func _test_hud_pure() -> void:
	print("Hearts shapes (pure)")
	var WorldScript = load("res://scripts/world.gd")  # runtime load: needs the GameState autoload
	check(HeartsScript.heart_count(10) == 5 and HeartsScript.heart_count(9) == 5, "10 halves draw 5 hearts")
	var states := []
	for i in 5:
		states.append(HeartsScript.heart_state(i, 7))
	check(states == [2, 2, 2, 1, 0], "7 halves = 3 full, 1 half, 1 empty (%s)" % str(states))
	var full := []
	var none := []
	for i in 5:
		full.append(HeartsScript.heart_state(i, 10))
		none.append(HeartsScript.heart_state(i, 0))
	check(full == [2, 2, 2, 2, 2] and none == [0, 0, 0, 0, 0], "10 halves all full, 0 halves all empty")
	check(HeartsScript.heart_state(0, 1) == 1 and HeartsScript.heart_state(1, 1) == 0, "1 half = half of the first heart")
	var poly: PackedVector2Array = HeartsScript.heart_polygon(52.0)
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	check(poly.size() >= 24 and lo.is_equal_approx(Vector2.ZERO) and hi.is_equal_approx(Vector2(52, 52)), "heart polygon fills its 52 px box")
	check(WorldScript.hearts_text(1) == "½" and WorldScript.hearts_text(2) == "1" and WorldScript.hearts_text(3) == "1½", "heart amounts read ½ / 1 / 1½")

	var eye: PackedVector2Array = EyesScript.eye_polygon(38.0, 22.0)
	var eye_lo := eye[0]
	var eye_hi := eye[0]
	for p in eye:
		eye_lo = Vector2(minf(eye_lo.x, p.x), minf(eye_lo.y, p.y))
		eye_hi = Vector2(maxf(eye_hi.x, p.x), maxf(eye_hi.y, p.y))
	check(eye_lo.is_equal_approx(Vector2.ZERO) and eye_hi.is_equal_approx(Vector2(38, 22)), "eye polygon fills its 38 x 22 box")
	var held_eyes := []
	for i in 7:
		held_eyes.append(EyesScript.eye_held(i, 3))
	check(held_eyes == [true, true, true, false, false, false, false], "3 held = the first 3 eyes filled")
	var cake: PackedVector2Array = DdeokIconScript.songpyeon_polygon(46.0, 26.0)
	var cake_lo := cake[0]
	var cake_hi := cake[0]
	for p in cake:
		cake_lo = Vector2(minf(cake_lo.x, p.x), minf(cake_lo.y, p.y))
		cake_hi = Vector2(maxf(cake_hi.x, p.x), maxf(cake_hi.y, p.y))
	check(cake_lo.is_equal_approx(Vector2.ZERO) and cake_hi.is_equal_approx(Vector2(46, 26)), "송편 polygon fills its 46 x 26 box")


## Counts the filled eyes the way _draw does.
func _eyes_shown(display: Control) -> int:
	var n := 0
	for i in display.cap:
		if EyesScript.eye_held(i, display.held):
			n += 1
	return n


func _test_hud_icons() -> void:
	print("HUD icons follow GameState")
	var gs := _gs()
	var world: Node = await _start_world()
	var hud: Node = world.hud
	var eyes: Control = hud.nunchi
	for n in [0, 3, 7]:
		gs.nunchi = 0
		if n > 0:
			gs.add_nunchi(n)
		await _frames(1)
		check(gs.nunchi == n and _eyes_shown(eyes) == n and eyes.cap == 7, "%d held eyes of 7 when 눈치 is %d" % [n, n])
	gs.nunchi = 0
	gs.nunchi_changed.emit(0)
	check(_eyes_shown(eyes) == 0, "eyes empty again at 눈치 0")
	check(eyes.get_child_count() == 0 and not hud.ddeok_label.text.contains("DDEOK"), "no number on the eyes, no DDEOK word on the count")
	for n in [0, 5, 12]:
		gs.ddeok = n
		gs.ddeok_changed.emit(n)
		check(hud.ddeok_label.text == str(n), "DDEOK count reads %d" % n)
	for h in [10, 7, 1, 0]:
		gs.hearts_halves = h
		gs.hearts_changed.emit(h)
		check(hud.hearts.halves == h, "hearts match %d halves" % h)
	# The dev arg's setter updates the HUD through the same signal.
	world.set_hearts_dev(5)
	check(gs.hearts_halves == 5 and hud.hearts.halves == 5, "--hearts 2.5 sets 5 halves and the HUD follows")
	world.set_hearts_dev(99)
	check(gs.hearts_halves == gs.hearts_max_halves, "the dev setter never exceeds the maximum")
	# Layout: every group sits inside the box, one under the other, no overlap.
	await _frames(2)
	var rects := []
	for c in [hud.hearts, eyes, hud.get_node("Box/Stats")]:
		rects.append(Rect2(c.global_position, c.size))
	var clear := true
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				clear = false
	check(clear, "hearts, eyes and the DDEOK/비밀 row do not overlap")
	var ddeok_row: Control = hud.get_node("Box/Stats/Ddeok")
	check(not Rect2(ddeok_row.global_position, ddeok_row.size).intersects(Rect2(hud.secrets_label.global_position, hud.secrets_label.size)), "DDEOK group and 비밀 do not overlap")
	check(Rect2(0, 0, 1920, 1080).encloses(Rect2(hud.get_node("Box").global_position, hud.get_node("Box").size)), "HUD fits inside 1920x1080")
	await _stop_world(world)


func _test_launch_args() -> void:
	print("Launch args")
	var WorldScript = load("res://scripts/world.gd")
	var none: Dictionary = WorldScript.parse_launch_args(PackedStringArray([]))
	check(not none["new_game"] and none["seed"] == -1 and not none["capture_map"] and not none["capture_hud"], "no args: load the save, random seed")
	var a: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--new-game", "--seed", "42"]))
	check(a["new_game"] and a["seed"] == 42, "--new-game and --seed N")
	var bad: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--seed", "abc"]))
	check(bad["seed"] == -1, "a bad --seed is ignored")
	var last: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--seed"]))
	check(last["seed"] == -1, "--seed with no value is ignored")
	check(WorldScript.parse_launch_args(PackedStringArray(["--capture-hud"]))["capture_hud"], "--capture-hud recognised")
	check(none["hearts_halves"] == -1, "no --hearts: hearts untouched")
	var hearts_cases := {"1": 2, "2.5": 5, "0.5": 1, "5": 10, "3.0": 6, "0": 1, "0.1": 1, "-3": 1, "9": 10, "100": 10, "2.4": 5, "2.2": 4}
	for text in hearts_cases:
		var got: int = WorldScript.parse_launch_args(PackedStringArray(["--hearts", text]))["hearts_halves"]
		check(got == hearts_cases[text], "--hearts %s -> %d halves (got %d)" % [text, hearts_cases[text], got])
	for junk in ["abc", "", "1.2.3", "nan", "inf", "2 hearts", "--seed"]:
		check(WorldScript.parse_launch_args(PackedStringArray(["--hearts", junk]))["hearts_halves"] == -1, "--hearts '%s' is ignored" % junk)
	check(WorldScript.parse_launch_args(PackedStringArray(["--hearts"]))["hearts_halves"] == -1, "--hearts with no value is ignored")
	var mixed: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--new-game", "--hearts", "1.5", "--seed", "9"]))
	check(mixed["hearts_halves"] == 3 and mixed["seed"] == 9 and mixed["new_game"], "--hearts combines with other args")


func _test_world_launch() -> void:
	print("World launch and saves")
	var gs := _gs()
	var world: Node = await _start_world()
	check(world.room_id == "hallway_1f" and gs.progress == "scene_01", "no save: new game in the start room")
	check(world.layout.size() == 5, "a layout of 5 finds was dealt on launch")
	check(world.hud != null and world.hud.get_parent() == world, "HUD is part of the world")

	# Forced seed: same seed, same layout.
	world._forced_seed = 777
	world._start_game(true)
	var l1: Dictionary = world.layout.duplicate(true)
	world._start_game(true)
	check(gs.spawn_seed == 777 and same(l1, world.layout), "--seed forces the spawn seed and so the layout")
	world._forced_seed = -1

	# Autosave on a room change; the save holds the state, and a relaunch starts in the start room.
	gs.add_ddeok(3)
	gs.mark_collected(MAP_KEY, "stove:ddeok")
	check(not FileAccess.file_exists(gs.save_path), "nothing is saved before the first room change")
	await _confirm_at(world, world.room.get_node("To_classroom_1_3"))
	check(world.room_id == "classroom_1_3" and FileAccess.file_exists(gs.save_path), "a room change autosaves")
	var other := make_gs()
	other.save_path = gs.save_path
	check(other.load_game() == OK and other.ddeok == 3 and other.is_collected(MAP_KEY, "stove:ddeok"), "save round trip across a room change")
	other.free()
	await _stop_world(world)

	var again: Node = await _start_world(true)
	check(again.room_id == "hallway_1f" and gs.ddeok == 3, "relaunch: state restored, but in the start room")
	check(not again.layout.has("stove"), "relaunch: the collected spot is not dealt again")
	var left := _kind_counts(again.layout)
	check(left["ddeok"] == 1 and left["trap"] == 2 and left["note"] + left["health"] == 1, "relaunch: taken + remaining = budget")
	# --new-game ignores the save.
	again._start_game(true)
	check(gs.ddeok == 0 and gs.collected.is_empty(), "--new-game ignores the save")
	await _stop_world(again)

	# A save from a newer version is never overwritten.
	_clean_world_saves()
	DirAccess.make_dir_recursive_absolute(WORLD_SAVE_DIR)
	var future := JSON.stringify({"game": "noraebang-night", "save_version": 99, "state_version": "9.9", "state": {"ddeok": 5}})
	_write(WORLD_SAVE_DIR + "/save.json", future)
	var w3: Node = await _start_world(true)
	check(not w3.autosave_enabled and gs.ddeok == 0, "newer save: new game in memory, autosave off")
	await _confirm_at(w3, w3.room.get_node("To_classroom_1_3"))
	check(_read(WORLD_SAVE_DIR + "/save.json") == future, "newer save is left untouched by a room change")
	await _stop_world(w3)


func _test_world_search() -> void:
	print("Searching")
	var gs := _gs()
	var cfg: Dictionary = DealerScript.load_config()
	var world: Node = await _start_world()
	var lines: Dictionary = cfg["lines"]
	world.layout = {
		"stove": {"kind": "ddeok", "amount": 1},
		"lectern": {"kind": "trap", "name": "쥐덫", "damage": 1},
		"cabinet": {"kind": "health", "item": "band_aid", "name": "반창고", "heal": 1},
		"back_chair": {"kind": "note", "note_id": "note_2"},
		"shoe_rack": {"kind": "health", "item": "red_medicine", "name": "빨간약", "heal": 2},
	}
	gs.damage(4)
	check(gs.hearts_halves == 6, "start the search test at 6 halves")

	var ok := await _search_spot(world, cfg, "stove")
	check(ok and world._text_open and world.player.movement_locked, "Enter on a spot opens the textbox and locks movement")
	check(gs.ddeok == 1 and world._text_label.text.contains("1 DDEOK") and world._text_label.text.contains("[placeholder]"), "DDEOK goes to GameState")
	check(gs.is_collected(MAP_KEY, "stove:ddeok"), "the find is recorded as stove:ddeok")
	await _close_text(world)
	await _search_spot(world, cfg, "stove")
	check(world._text_label.text == lines["searched"] and gs.ddeok == 1, "a spot searched twice gives nothing the second time")
	check(gs.collected[MAP_KEY].size() == 1, "the second search records nothing")
	await _close_text(world)

	await _search_spot(world, cfg, "back_chair")
	check(gs.has_note("note_2") and world._text_label.text.contains(cfg["notes"]["note_2"]), "a note goes to GameState and its text is shown")
	await _close_text(world)
	await _search_spot(world, cfg, "cabinet")
	check(gs.hearts_halves == 7 and world._text_label.text.contains("반창고") and world._text_label.text.contains("½"), "반창고 heals 1 half at once")
	await _close_text(world)
	await _search_spot(world, cfg, "shoe_rack")
	check(gs.hearts_halves == 9 and world._text_label.text.contains("빨간약"), "빨간약 heals 2 halves at once")
	await _close_text(world)
	var before_flash: int = world.flashes
	await _search_spot(world, cfg, "lectern")
	check(gs.hearts_halves == 8 and world._text_label.text.contains("쥐덫") and world._text_label.text.contains("½"), "a ½-heart trap costs 1 half")
	check(world.flashes == before_flash + 1 and world._flash_rect.color.a > 0.0, "a trap flashes the screen red")
	await _close_text(world)

	# Nothing dealt: empty, still once only.
	await _search_spot(world, cfg, "restroom")
	check(world._text_label.text == lines["empty"] and gs.is_collected(MAP_KEY, "restroom:empty"), "an undealt spot is empty and recorded")
	await _close_text(world)

	# Hearts clamp at the maximum.
	gs.hearts_halves = gs.hearts_max_halves
	world.layout = {"sandbox": {"kind": "health", "item": "red_medicine", "name": "빨간약", "heal": 2}}
	await _search_spot(world, cfg, "sandbox")
	check(gs.hearts_halves == gs.hearts_max_halves, "healing clamps at full hearts")
	await _close_text(world)

	# A 1-heart trap.
	world.layout = {"iron_bar": {"kind": "trap", "name": "녹슨 철봉", "damage": 2}}
	await _search_spot(world, cfg, "iron_bar")
	check(gs.hearts_halves == gs.hearts_max_halves - 2 and world._text_label.text.contains("1 heart"), "a 1-heart trap costs 2 halves")
	await _close_text(world)

	# The HUD follows GameState.
	await _frames(1)
	check(world.hud.hearts.halves == gs.hearts_halves and world.hud.hearts.max_halves == gs.hearts_max_halves, "HUD hearts match GameState (%d halves)" % gs.hearts_halves)
	check(world.hud.ddeok_label.text == str(gs.ddeok) and world.hud.nunchi.held == gs.nunchi and world.hud.nunchi.cap == 7, "HUD DDEOK count and 눈치 eyes match")
	check(world.hud.secrets_label.text == "비밀 7/7", "HUD shows 비밀 7/7 at the start")
	gs.lose_secret("pride", "eunju")
	gs.add_nunchi(2)
	gs.damage(1)
	check(world.hud.secrets_label.text == "비밀 6/7" and world.hud.nunchi.held == 2 and world.hud.hearts.halves == gs.hearts_halves, "HUD updates on signals")

	# Death: game over, then Enter restarts in 1학년 3반 with a fresh GameState.
	gs.hearts_halves = 1
	world.layout = {"statue": {"kind": "trap", "name": "이순신 동상의 칼", "damage": 2}}
	await _search_spot(world, cfg, "statue")
	check(world._game_over and world._game_over_layer.visible and world.player.movement_locked, "0 hearts: GAME OVER screen, movement locked")
	check(gs.hearts_halves == 0 and world.hud.hearts.halves == 0, "the HUD shows empty hearts on the game-over screen")
	await _press("confirm")
	check(not world._game_over and not world._game_over_layer.visible and not world._text_open, "Enter leaves the game-over screen")
	check(world.room_id == "classroom_1_3" and is_equal_approx(world.player.position.x, 7.0), "death restarts in 1학년 3반 at its door")
	check(gs.hearts_halves == gs.hearts_max_halves and gs.ddeok == 0 and gs.notes.is_empty() and gs.collected.is_empty() and gs.progress == "scene_01" and gs.map_day == "sat", "GameState is fresh after the death reset")
	check(not world.player.movement_locked, "movement is unlocked after the restart")
	check(world.layout.size() == 5 and gs.secrets_held.size() == gs.hand.size(), "a new layout is dealt and the hand is restored")
	var saved := make_gs()
	saved.save_path = gs.save_path
	check(saved.load_game() == OK and saved.hearts_halves == saved.hearts_max_halves and saved.collected.is_empty(), "the death reset is autosaved")
	saved.free()
	check(world.hud.hearts.halves == gs.hearts_max_halves and world.hud.secrets_label.text == "비밀 7/7", "HUD shows the fresh state")
	await _stop_world(world)


## Searches all the day's spots through real key presses and checks the budget.
func _test_world_full_run() -> void:
	print("Full run through the spots")
	var gs := _gs()
	var cfg: Dictionary = DealerScript.load_config()
	var spots: Dictionary = cfg["spots"]
	for day in ["sat", "mon"]:
		var world: Node = await _start_world()
		gs.map_day = day
		gs.spawn_seed = 31337
		world.deal_layout()
		var layout: Dictionary = world.layout.duplicate(true)
		var ids: Array = spots.keys().filter(func(id): return spots[id]["days"].has(day))
		ids.sort()
		var reachable := true
		var expected_hearts: int = gs.hearts_halves
		for id in ids:
			var reached: bool = await _search_spot(world, cfg, id)
			reachable = reachable and reached
			await _close_text(world)
			var entry: Dictionary = layout.get(id, {"kind": "empty"})
			if entry["kind"] == "trap":
				expected_hearts = maxi(expected_hearts - int(entry["damage"]), 1)
			elif entry["kind"] == "health":
				expected_hearts = mini(expected_hearts + int(entry["heal"]), gs.hearts_max_halves)
		check(reachable, "%s: all %d spots can be reached and searched with Enter" % [day, ids.size()])
		var tally := {"ddeok": 0, "note": 0, "health": 0, "trap": 0, "empty": 0}
		for entry in gs.collected["map_01:" + day]:
			tally[str(entry).split(":")[1]] += 1
		check(tally["ddeok"] == 2 and tally["note"] + tally["health"] == 1 and tally["trap"] == 2 and tally["empty"] == ids.size() - 5, "%s: the run found exactly the day's budget %s" % [day, str(tally)])
		check(gs.ddeok == 2, "%s: 2 DDEOK in GameState" % day)
		check(gs.notes.size() == tally["note"], "%s: notes match the finds" % day)
		check(gs.hearts_halves == expected_hearts, "%s: hearts match the traps and health items found (%d halves)" % [day, gs.hearts_halves])
		check(gs.collected["map_01:" + day].size() == ids.size(), "%s: every spot recorded once" % day)
		if day == "mon":
			check(ids.has("landing_2f") and gs.is_collected("map_01:mon", "landing_2f:" + layout.get("landing_2f", {"kind": "empty"})["kind"]), "mon: the 2층 landing was searched")
		await _stop_world(world)
	_clean_world_saves()


# ── Step 3a: dialogue and Scene 01 ─────────────────────────────────────

const DIALOGUE_PATH := "res://data/dialogue/scene_01.dialogue"
const SCRIPT_DOC := "res://docs/scripts/scene-01-eunju-scene-1-v0.2.md"
## Loaded at run time: the box script needs the DialogueManager autoload.
const DIALOGUE_BOX_PATH := "res://scenes/ui/dialogue_box.tscn"
const SPEAKERS := ["박철수", "오동진", "은주", "미숙", "미경", "최은주", "한은주"]


## Stands in for the scene director: records the stage directions it is asked for.
class StageStub:
	extends RefCounted
	var calls: Array = []

	func teacher_exits(): calls.append("teacher_exits")
	func first_line_pause(): calls.append("first_line_pause")
	func eunju_arrives(): calls.append("eunju_arrives")
	func giggle(): calls.append("giggle")
	func grab_nameplate(): calls.append("grab_nameplate")
	func class_laughs(): calls.append("class_laughs")
	func raise_hands(): calls.append("raise_hands")
	func drop_nameplate(): calls.append("drop_nameplate")
	func bell(): calls.append("bell")
	func eunju_returns(): calls.append("eunju_returns")
	func eunju_looks_back(): calls.append("eunju_looks_back")


## The three choice points as the doc writes them: [[{"text", "effect"}, ...], ...].
func _doc_choices() -> Array:
	var points: Array = []
	var current: Array = []
	var lines := FileAccess.get_file_as_string(SCRIPT_DOC).split("\n")
	for i in lines.size():
		var line: String = lines[i]
		if line.begins_with("01-E"):
			break
		if line.begins_with("01-") and line.contains("CHOICE"):
			current = []
			points.append(current)
		if line.begins_with("▸ "):
			var rest := line.substr(2).strip_edges()
			rest = rest.substr(1).strip_edges()  # drop the option letter
			if rest.begins_with("\"") and rest.ends_with("\""):
				rest = rest.substr(1, rest.length() - 2)
			var effect := ""
			for j in range(i + 1, mini(i + 3, lines.size())):
				if lines[j].strip_edges().begins_with("→"):
					effect = lines[j].strip_edges().substr(1).strip_edges()
					break
			current.append({"text": rest, "effect": effect})
	return points


func _card_ids_by_name() -> Dictionary:
	var ids := {}
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/secrets/act1_cards.json"))
	for card in data["cards"]:
		ids[card["name"]] = card["id"]
	return ids


## Plays one cue in a real DialogueBox, choosing `picks[n]` at the nth choice.
## Returns {"lines": ["은주: ...", ...], "asked": int}.
func _run_cue(box: Node, res: Resource, cue: String, stub: RefCounted, picks: Array) -> Dictionary:
	var lines: Array = []
	var record := func(c: String, t: String): lines.append("%s: %s" % [c, t])
	box.line_shown.connect(record)
	box.play(res, cue, [stub])
	var asked := 0
	var guard := 0
	while guard < 600:
		await process_frame
		guard += 1
		if box.choosing:
			box.choose(picks[asked])
			asked += 1
		elif box.waiting:
			box.advance()
		elif not box.is_open:
			break
	box.line_shown.disconnect(record)
	return {"lines": lines, "asked": asked}


func _snapshot(gs: Node) -> Dictionary:
	return gs._current_state()


func _changed_keys(before: Dictionary, after: Dictionary) -> Array:
	var keys := []
	for k in after:
		if var_to_str(before[k]) != var_to_str(after[k]):
			keys.append(k)
	keys.sort()
	return keys


func _test_dialogue_file() -> void:
	print("scene_01.dialogue")
	var text := FileAccess.get_file_as_string(DIALOGUE_PATH)
	check(text != "", "scene_01.dialogue exists")
	var result: DMCompilerResult = DMCompiler.compile_string(text, DIALOGUE_PATH)
	check(result.errors.is_empty(), "scene_01.dialogue compiles with Dialogue Manager (%d errors)" % result.errors.size())
	var res = load(DIALOGUE_PATH)
	check(res != null and res.lines.size() > 0, "scene_01.dialogue loads as a DialogueResource")
	check(res.cues.has("a") and res.cues.has("a3"), "cues a (01-A) and a3 (01-A3 to 01-E) exist")
	check(not text.contains("GameState.add_ddeok") and not text.contains("GameState.damage"), "the file uses only set_boss / add_nunchi / lose_secret")
	# Hand ids and the card list agree (so the card list can give display names).
	var gs := _gs()
	var names := _card_ids_by_name()
	var ids: Array = names.values()
	ids.sort()
	var hand: Array = gs.hand.duplicate()
	hand.sort()
	check(ids == hand, "act1_cards.json uses the same card ids as act1_hand.json")


func _test_script_matches_doc() -> void:
	print("Script check against the doc")
	var doc := FileAccess.get_file_as_string(SCRIPT_DOC)
	check(doc != "", "the v0.2 script doc is readable")
	var block_start := doc.find("## Script")
	var fence := doc.find("```", block_start)
	var block := doc.substr(fence + 3, doc.find("```", fence + 3) - fence - 3)
	var english := RegEx.create_from_string("\\s*\\([^)]*[A-Za-z][^)]*\\)")
	var speaker_line := RegEx.create_from_string("^\\s*(" + "|".join(SPEAKERS) + "):\\s+(.*)$")
	var doc_lines := []  # "speaker|text" and "-|choice"
	for raw in block.split("\n"):
		var line: String = raw
		var m := speaker_line.search(line)
		if m != null:
			var spoken := english.sub(m.get_string(2), "", true).strip_edges()
			doc_lines.append("%s|%s" % [m.get_string(1), spoken])
			continue
		if line.strip_edges().begins_with("▸ "):
			var rest := line.strip_edges().substr(2).strip_edges().substr(1).strip_edges()
			if rest.begins_with("\"") and rest.ends_with("\""):
				rest = rest.substr(1, rest.length() - 2)
			doc_lines.append("-|%s" % rest)
	check(doc_lines.size() >= 30, "found the doc's Korean lines (%d)" % doc_lines.size())
	var file_lines := []
	var file_speaker := RegEx.create_from_string("^(" + "|".join(SPEAKERS) + "):\\s+(.*)$")
	for raw in FileAccess.get_file_as_string(DIALOGUE_PATH).split("\n"):
		var line: String = raw.strip_edges()
		var m := file_speaker.search(line)
		if m != null:
			file_lines.append("%s|%s" % [m.get_string(1), m.get_string(2)])
		elif line.begins_with("- "):
			file_lines.append("-|%s" % line.substr(2))
	var missing := doc_lines.filter(func(l): return not file_lines.has(l))
	var extra := file_lines.filter(func(l): return not doc_lines.has(l))
	check(missing.is_empty(), "every Korean line in the doc appears verbatim in scene_01.dialogue %s" % str(missing))
	check(extra.is_empty(), "scene_01.dialogue has no Korean line the doc lacks %s" % str(extra))
	check(doc_lines.size() == file_lines.size(), "same number of lines (%d doc, %d file)" % [doc_lines.size(), file_lines.size()])


func _test_choice_effects() -> void:
	print("Choice effects")
	var gs := _gs()
	var res = load(DIALOGUE_PATH)
	var names := _card_ids_by_name()
	var points := _doc_choices()
	check(points.size() == 3 and points[0].size() == 4 and points[1].size() == 3 and points[2].size() == 4, "the doc has 3 choice points with 4 / 3 / 4 options")
	var box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(box)
	await _frames(2)
	# Neutral option at each point: the one that does nothing.
	var neutral := []
	for point in points:
		for i in point.size():
			if point[i]["effect"] == "nothing":
				neutral.append(i)
	check(neutral.size() == 3, "each point has one neutral option")
	var all_one := true
	for k in points.size():
		for i in points[k].size():
			var opt: Dictionary = points[k][i]
			gs.new_game()
			var stub := StageStub.new()
			await _run_cue(box, res, "a", stub, [])
			var before := _snapshot(gs)
			var picks: Array = neutral.duplicate()
			picks[k] = i
			var ran := await _run_cue(box, res, "a3", stub, picks)
			var after := _snapshot(gs)
			var keys := _changed_keys(before, after)
			var effect: String = opt["effect"]
			var label := "choice %d option %d (%s)" % [k + 1, i + 1, effect]
			check(ran["asked"] == 3, label + ": all three choices were asked")
			if effect == "nothing":
				check(keys.is_empty(), label + ": changes nothing %s" % str(keys))
			elif effect.contains("눈치"):
				check(keys == ["nunchi"] and after["nunchi"] == before["nunchi"] + 1, label + ": +1 눈치 and nothing else %s" % str(keys))
			else:
				var card: String = names.get(effect.split("🔒")[1].strip_edges(), "?")
				var lost: Array = before["secrets_held"].filter(func(c): return not after["secrets_held"].has(c))
				var one: bool = keys == ["secrets_held", "secrets_known_by"] and lost == [card] and after["secrets_held"].size() == before["secrets_held"].size() - 1
				check(one, label + ": loses exactly %s %s" % [card, str(keys)])
				all_one = all_one and one
	check(all_one, "every card-losing option loses exactly one card")
	box.queue_free()
	await _frames(1)


func _test_choice_paths() -> void:
	print("Choice paths")
	var gs := _gs()
	var res = load(DIALOGUE_PATH)
	var box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(box)
	await _frames(2)
	# 1A, 2B, 3A.
	gs.new_game()
	await _run_cue(box, res, "a", StageStub.new(), [])
	await _run_cue(box, res, "a3", StageStub.new(), [0, 1, 0])
	check(gs.nunchi == 3 and gs.secrets_held.size() == gs.hand.size(), "the max 눈치 path (1A, 2B, 3A) gives +3 눈치 and loses nothing")
	# Cards lost along 1B, 2A, 3C are known by 은주.
	gs.new_game()
	await _run_cue(box, res, "a", StageStub.new(), [])
	await _run_cue(box, res, "a3", StageStub.new(), [1, 0, 2])
	check(gs.current_boss == "eunju", "set_boss(eunju) ran in 01-A")
	check(gs.knows("eunju", "dad_country") and gs.knows("eunju", "pride") and gs.knows("eunju", "dad_drinking"), "lost cards are known by eunju")
	check(not gs.has_secret("dad_country") and not gs.has_secret("pride") and not gs.has_secret("dad_drinking") and gs.nunchi == 0, "3 cards lost, no 눈치")
	# 자존심 twice: 1C then 2A costs nothing more.
	gs.new_game()
	await _run_cue(box, res, "a", StageStub.new(), [])
	await _run_cue(box, res, "a3", StageStub.new(), [2, 0, 3])
	check(gs.secrets_held.size() == gs.hand.size() - 1 and not gs.has_secret("pride"), "자존심 lost twice (1C, 2A) costs one card, not two")
	check(gs.lose_secret("pride") == false, "losing an already-lost card changes nothing")
	# The Scene 00 line plays only when 자존심 is gone.
	gs.new_game()
	var stub := StageStub.new()
	await _run_cue(box, res, "a", stub, [])
	var held := await _run_cue(box, res, "a3", stub, [3, 2, 3])
	check(not held["lines"].has("은주: 아까 반장한테 \"미안해…\" 했지?") and not stub.calls.has("giggle"), "자존심 held: no 반장 line, no giggle")
	gs.new_game()
	gs.lose_secret("pride", "someone")
	stub = StageStub.new()
	await _run_cue(box, res, "a", stub, [])
	var lost := await _run_cue(box, res, "a3", stub, [3, 2, 3])
	check(lost["lines"].has("은주: 아까 반장한테 \"미안해…\" 했지?") and stub.calls.has("giggle"), "자존심 lost: the 반장 line plays and 미숙 and 미경 giggle")
	check(stub.calls.has("eunju_arrives") and stub.calls.has("bell") and stub.calls.has("eunju_returns"), "stage directions are called on the director")
	gs.new_game()
	box.queue_free()
	await _frames(1)


func _test_dialogue_box() -> void:
	print("Dialogue box input")
	var gs := _gs()
	var res = load(DIALOGUE_PATH)
	gs.new_game()
	var box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(box)
	await _frames(2)
	var picked := []
	box.choice_made.connect(func(i: int, t: String): picked.append(i))
	box.play(res, "a", [StageStub.new()])
	await _frames(3)
	check(box.is_open and box.waiting and box.visible, "the box opens on the first line")
	check(box.get_node("Root/Stack/Panel/Box/Speaker").text == "박철수" and box.get_node("Root/Stack/Panel/Box/Line").text == "오늘도 만화 안 해?", "speaker and line are shown")
	await _press("confirm")
	check(box.get_node("Root/Stack/Panel/Box/Line").text == "몰라. 딱지나 해.", "Enter advances")
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	Input.parse_input_event(e)
	await _frames(3)
	check(not box.is_open, "a click advances (and the last line closes the box)")
	box.play(res, "a3", [StageStub.new()])
	await _frames(4)
	var guard := 0
	while not box.choosing and guard < 60:
		if box.waiting:
			box.advance()
		await _frames(1)
		guard += 1
	check(box.choosing and box._rows.size() == 4 and box.highlighted == 0, "Choice 1 shows 4 options, the first highlighted")
	await _press("ui_down")
	check(box.highlighted == 1, "S / down moves the highlight")
	for i in 6:
		await _press("ui_down")
	check(box.highlighted == 3, "the highlight stops at the last option")
	await _press("ui_up")
	check(box.highlighted == 2, "W / up moves it back")
	await _press("confirm")
	check(picked == [2], "Enter picks the highlighted option (picked %s)" % str(picked))
	guard = 0
	while not box.choosing and guard < 80:
		if box.waiting:
			box.advance()
		await _frames(1)
		guard += 1
	check(box.choosing and box._rows.size() == 3, "Choice 2 shows 3 options")
	# A click on the second row picks it.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	box._rows[1].gui_input.emit(click)
	await _frames(2)
	check(picked == [2, 1], "clicking an option picks it (picked %s)" % str(picked))
	box.cancel()
	await _frames(2)
	check(not box.is_open and not box.visible, "cancel closes the box")
	gs.new_game()
	box.queue_free()
	await _frames(1)


func _test_hud_cues() -> void:
	print("HUD choice cues")
	var gs := _gs()
	var world: Node = await _start_world()
	var hud: Node = world.hud
	var names: Dictionary = hud.load_card_names()
	check(names.size() == 7 and names["dad_country"] == "아빠 나라", "card names load from act1_cards.json")
	gs.add_nunchi(1)
	await _frames(1)
	check(hud.last_cue == "+1" and hud.cue_count == 1, "+1 cue appears after a 눈치 gain")
	gs.lose_secret("dad_country", "eunju")
	await _frames(1)
	check(hud.last_cue == "아빠 나라" and hud.cue_count == 2, "a lock cue with the card's name appears after a loss")
	gs.lose_secret("dad_country", "eunju")
	await _frames(1)
	check(hud.cue_count == 2, "a card that is already lost shows no second cue")
	await _stop_world(world)


## Steps a running scene: advance lines, pick at choices. Samples movement_locked.
func _drive_scene(world: Node, picks: Array, stop_when: Callable, samples: Dictionary = {}) -> int:
	var asked := 0
	var guard := 0
	var box: Node = world.dialogue_box
	while guard < 1500 and not stop_when.call():
		await process_frame
		guard += 1
		var phase: String = world.director.phase
		if samples.has(phase):
			samples[phase].append(world.player.movement_locked)
		if stop_when.call():
			break
		if box.choosing:
			box.choose(picks[asked])
			asked += 1
		elif box.waiting:
			box.advance()
		elif phase == "a2":
			world.director.a2_elapsed = 1e9
	return asked


func _test_scene_flow() -> void:
	print("Scene 01 flow")
	var gs := _gs()
	var world: Node = await _start_world(false, true)
	world.director.time_scale = 40.0
	await _frames(3)
	check(world.room_id == "classroom_1_3" and is_equal_approx(world.player.position.x, 7.0), "a new game starts in 1학년 3반 at its door")
	check(gs.progress == "scene_01" and world.director.phase == "a", "progress scene_01, scene at 01-A")
	check(FileAccess.file_exists(gs.save_path), "Scene 01 autosaves at its start")
	var saved := make_gs()
	saved.save_path = gs.save_path
	check(saved.load_game() == OK and saved.progress == "scene_01", "the start-of-scene save says scene_01")
	saved.free()
	var open_wait := 0
	while not world.dialogue_box.is_open and open_wait < 200:
		await _frames(1)
		open_wait += 1
	check(world.player.movement_locked and world.dialogue_box.is_open, "01-A: movement locked, dialogue open")
	check(world.director.actors.size() == 8, "8 placeholder actors are in the room")
	var names := []
	for a in world.director.actors.values():
		names.append(a.display_name)
	names.sort()
	var want := ["미경", "미숙", "박철수", "오경자 선생님", "오동진", "은주", "최은주", "한은주"]
	want.sort()
	check(names == want, "actors are 은주, 미숙, 미경, 박철수, 오동진, 최은주, 한은주, 오경자 선생님")
	# A door cannot be used while the scene runs.
	await _drive_scene(world, [], func(): return world.director.phase == "a2")
	check(world.director.phase == "a2" and not world.player.movement_locked, "01-A2: movement unlocked")
	var wait := 0
	while world.director.actors["teacher"].visible and wait < 300:
		await _frames(1)
		wait += 1
	check(not world.director.actors["teacher"].visible, "the teacher has left")
	await _confirm_at(world, world.room.get_node("To_hallway_1f"))
	check(world.room_id == "classroom_1_3" and world._text_label.text == world.SCENE_EXIT_LINE, "the door stays shut during the scene")
	await _close_text(world)
	# Proximity: walking to 은주's desk starts 01-A3 at once.
	world.director.a2_elapsed = 0.0
	world.player.place(3.0 + 1.0, 0)
	await _frames(3)
	check(world.director.phase == "a3" and world.director.a3_trigger == "proximity", "walking within reach of 은주's desk starts 01-A3")
	check(world.player.movement_locked, "01-A3: movement locked")
	# Locked from 01-A3 to 01-E, 은주 at 보람's side, then 01-F.
	var asked := await _drive_scene(world, [0, 1, 0], func(): return world.director.phase == "a3" and world.dialogue_box.choosing)
	var eunju: Node3D = world.director.actors["eunju"]
	check(absf(eunju.position.x - world.player.position.x) < 1.6 and absf(eunju.position.z - world.player.position.z) < 0.5, "은주 stands in front of 보람 (%.2f vs %.2f)" % [eunju.position.x, world.player.position.x])
	var samples := {"a3": []}
	asked += await _drive_scene(world, [0, 1, 0], func(): return world.director.phase == "f", samples)
	check(samples["a3"].size() > 10 and not samples["a3"].has(false), "movement stayed locked through 01-A3 to 01-E (%d samples)" % samples["a3"].size())
	await _frames(3)
	check(world.director.phase == "f" and not world.player.movement_locked and not world.dialogue_box.is_open, "01-F: movement unlocked")
	check(gs.progress == "sat_roam" and gs.nunchi == 3, "progress sat_roam; the max path gave 3 눈치")
	check(world.director.actors.is_empty() and world.room.find_children("*", "Node3D", true, false).filter(func(n): return n.has_method("walk_to")).is_empty(), "the classroom is empty in 01-F")
	var again := make_gs()
	again.save_path = gs.save_path
	check(again.load_game() == OK and again.progress == "sat_roam" and again.nunchi == 3, "01-F autosaves (sat_roam, with the choices' results)")
	again.free()
	# Doors work again.
	await _confirm_at(world, world.room.get_node("To_hallway_1f"))
	check(world.room_id == "hallway_1f", "01-F: 보람 can leave the classroom")
	await _stop_world(world)

	# The 10 second trigger.
	world = await _start_world(false, true)
	world.director.time_scale = 40.0
	await _drive_scene(world, [], func(): return world.director.phase == "a2")
	world.player.place(-8.0, 0)
	world.director.a2_elapsed = 9.0
	await _frames(1)
	check(world.director.phase == "a2", "just under 10 s: still free")
	world.director.a2_elapsed = 9.99
	world.director._a2_tick(0.02)
	check(world.director.phase == "a3" and world.director.a3_trigger == "timeout", "after 10 s 01-A3 starts, with 보람 far from the desk")
	await _drive_scene(world, [0, 0, 0], func(): return world.dialogue_box.choosing)
	var far: Node3D = world.director.actors["eunju"]
	check(absf(far.position.x - world.player.position.x) < 1.6, "은주 walks to 보람 wherever she is (보람 at x %.1f, 은주 at %.1f)" % [world.player.position.x, far.position.x])
	await _stop_world(world)

	# A search spot's text box is closed when 01-A3 starts.
	world = await _start_world(false, true)
	world.director.time_scale = 40.0
	await _drive_scene(world, [], func(): return world.director.phase == "a2")
	world.show_text("(test)")
	world.director.a2_elapsed = 1e9
	await _frames(4)
	check(world.director.phase == "a3" and not world._text_open, "an open text box is closed when 01-A3 starts")
	await _stop_world(world)


func _test_days_and_resume() -> void:
	print("Days, doors and resume")
	var gs := _gs()
	var world: Node = await _start_world()
	world._load_room("stairs", "")
	var up: Node3D = world.room.get_node("To_hallway_2f")
	check(gs.map_day == "sat" and world.door_locked(up), "sat: the stairs -> 2층 복도 door is locked")
	world._load_room("alley", "")
	check(world.door_locked(world.room.get_node("To_stationery")), "sat: the 문방구 door is locked")
	gs.map_day = "mon"
	world._load_room("stairs", "")
	check(not world.door_locked(world.room.get_node("To_hallway_2f")), "mon: the 2층 door is open")
	world._load_room("alley", "")
	check(world.door_locked(world.room.get_node("To_stationery")), "mon: the 문방구 stays locked")
	world._load_room("stairs", "")
	await _confirm_at(world, world.room.get_node("To_hallway_2f"))
	check(world.room_id == "hallway_2f", "mon: Enter at the 2층 door goes up")
	gs.map_day = "sat"
	await _stop_world(world)

	# Saturday ends at the 교문 -> 골목길 door, only during sat_roam.
	world = await _start_world()
	world._forced_seed = 5
	gs.set_progress("mon")
	world._load_room("gate", "")
	await _confirm_at(world, world.room.get_node("To_alley"))
	check(world.room_id == "alley" and gs.map_day == "sat", "outside sat_roam the gate door is an ordinary door")
	await _stop_world(world)

	world = await _start_world()
	world._forced_seed = 5
	world.fade_time = 0.02
	world.title_hold = 0.4
	gs.set_progress("sat_roam")
	gs.add_ddeok(1)
	gs.mark_collected("map_01:sat", "stove:ddeok")
	var before_seed: int = gs.spawn_seed
	world._load_room("gate", "")
	world.player.place(world.room.get_node("To_alley").position.x, 0)
	await _frames(3)
	await _press("confirm")
	var guard := 0
	while not world._title_label.visible and guard < 60:
		await process_frame
		guard += 1
	check(world._title_label.visible and world._title_label.text == "1979년 10월 29일 월요일" and world.player.movement_locked, "the title card shows 1979년 10월 29일 월요일 over black")
	await _wait_transition(world)
	var fade_wait := 0
	while world._fade_rect.color.a > 0.0 and fade_wait < 200:
		await _frames(1)
		fade_wait += 1
	check(not world._title_label.visible and world._fade_rect.color.a == 0.0, "the card and the fade clear afterwards")
	check(gs.map_day == "mon" and gs.progress == "scene_02", "map_day mon, progress scene_02")
	check(world.room_id == "classroom_1_3" and world.player.movement_locked and world.director.phase == "s2", "Scene 02 starts in 1학년 3반 with movement locked")
	check(world.layout.size() == 5 and gs.spawn_seed != before_seed, "the day was re-dealt (5 finds)")
	check(gs.ddeok == 1 and not gs.collected.has("map_01:mon"), "Saturday's finds are kept; Monday starts with none collected")
	var again := make_gs()
	again.save_path = gs.save_path
	check(again.load_game() == OK and again.map_day == "mon" and again.progress == "scene_02" and again.ddeok == 1, "Scene 02 is autosaved at its start")
	again.free()
	await _stop_world(world)

	# Death during sat_roam restarts at 01-A with a fresh state.
	world = await _start_world(false, true)
	world.director.time_scale = 40.0
	await _drive_scene(world, [0, 1, 0], func(): return world.director.phase == "f")
	await _frames(3)
	check(gs.progress == "sat_roam" and gs.nunchi == 3, "(setup) in sat_roam with 3 눈치")
	gs.hearts_halves = 1
	gs.damage(1)
	await _frames(2)
	check(world._game_over, "dying in sat_roam shows GAME OVER")
	await _press("confirm")
	await _frames(3)
	check(world.room_id == "classroom_1_3" and is_equal_approx(world.player.position.x, 7.0), "death restarts in 1학년 3반 at its door")
	check(world.director.phase == "a" and world.dialogue_box.is_open and gs.progress == "scene_01", "death restarts Scene 01 at 01-A")
	check(gs.nunchi == 0 and gs.hearts_halves == gs.hearts_max_halves and gs.secrets_held.size() == gs.hand.size() and gs.map_day == "sat", "the state is fresh after the restart")
	check(world.player.movement_locked, "01-A is locked again")
	await _stop_world(world)

	# Resume from the saved progress step.
	for step in ["sat_roam", "mon_roam"]:
		var save := make_gs()
		save.save_path = WORLD_SAVE_DIR + "/save.json"
		DirAccess.make_dir_recursive_absolute(WORLD_SAVE_DIR)
		save.set_progress(step)
		save.map_day = "mon" if step == "mon_roam" else "sat"
		save.add_ddeok(4)
		save.save_game()
		save.free()
		world = await _start_world(true, true)
		check(gs.progress == step and gs.ddeok == 4, "resume %s: the save loads" % step)
		check(world.room_id == "classroom_1_3" and not world.player.movement_locked and not world.dialogue_box.is_open, "resume %s: starts in 1학년 3반, free to move" % step)
		check(world.director.actors.is_empty(), "resume %s: no scene plays" % step)
		check(gs.map_day == ("mon" if step == "mon_roam" else "sat"), "resume %s: map_day %s" % [step, gs.map_day])
		await _stop_world(world)
	var scene_save := make_gs()
	DirAccess.make_dir_recursive_absolute(WORLD_SAVE_DIR)
	scene_save.save_path = WORLD_SAVE_DIR + "/save.json"
	scene_save.set_progress("scene_01")
	scene_save.save_game()
	scene_save.free()
	world = await _start_world(true, true)
	check(world.director.phase == "a" and world.player.movement_locked, "resume scene_01: Scene 01 starts again at 01-A")
	await _stop_world(world)


func _test_skip_to() -> void:
	print("--skip-to")
	var WorldScript = load("res://scripts/world.gd")
	var none: Dictionary = WorldScript.parse_launch_args(PackedStringArray([]))
	check(none["skip_to"] == "", "no --skip-to: nothing")
	for step in ["scene_01", "sat_roam", "scene_02", "mon_walk", "mon_roam", "mon"]:
		check(WorldScript.parse_launch_args(PackedStringArray(["--skip-to", step]))["skip_to"] == step, "--skip-to %s" % step)
	for junk in ["scene_00", "tue", "", "--seed", "sat2_pending"]:
		check(WorldScript.parse_launch_args(PackedStringArray(["--skip-to", junk]))["skip_to"] == "", "--skip-to '%s' is ignored" % junk)
	check(WorldScript.parse_launch_args(PackedStringArray(["--skip-to"]))["skip_to"] == "", "--skip-to with no value is ignored")
	var gs := _gs()
	var world: Node = await _start_world()
	world._apply_skip_to("mon")
	check(gs.progress == "scene_02" and gs.map_day == "mon" and world.layout.size() == 5, "skip to mon (an alias of scene_02): progress, day and a Monday deal")
	await _stop_world(world)
	world = await _start_world()
	world._apply_skip_to("sat_roam")
	check(gs.progress == "sat_roam" and gs.map_day == "sat", "skip to sat_roam: progress and Saturday")
	await _stop_world(world)
	_clean_world_saves()


# ── Step 3b: Scene 02, the walk home, optional conversations, polish ───

const SCENE2_DIALOGUE := "res://data/dialogue/scene_02.dialogue"
const SCENE2_DOC := "res://docs/scripts/scene-02-eunju-scene-2-v0.2.md"
const OC_DIALOGUE := "res://data/dialogue/optional_sat.dialogue"
const OC_DOC := "res://docs/scripts/optional-conversations-sat-v0.1.md"
const ALL_SPEAKERS := ["박철수", "오동진", "은주", "미숙", "미경", "최은주", "한은주", "최은주·한은주",
		"손미숙", "손미경", "손미숙·손미경", "현정", "문태식", "철수", "동진", "상훈", "오경자"]


## Stands in for the director for the 3b cues (and 01's new pause).
class Stage3bStub:
	extends StageStub

	func eunju_hands_out(): calls.append("eunju_hands_out")
	func hyunjeong_raises_hand(): calls.append("hyunjeong_raises_hand")
	func eunju_passes_boram(): calls.append("eunju_passes_boram")
	func hyunjeong_leans(): calls.append("hyunjeong_leans")
	func eunju_to_front(): calls.append("eunju_to_front")
	func class_turns(): calls.append("class_turns")
	func show_form(): calls.append("show_form")
	func hide_form(): calls.append("hide_form")
	func eunju_reads(): calls.append("eunju_reads")
	func cheolsu_reads(): calls.append("cheolsu_reads")
	func hyunjeong_leaves(): calls.append("hyunjeong_leaves")
	func notebook_closes(): calls.append("notebook_closes")
	func fly_splat(): calls.append("fly_splat")
	func wipe_stick(): calls.append("wipe_stick")


## Korean lines of a doc's script block (as "speaker|text" / "-|choice"), stripped
## of English stage directions and quotes around spoken choices.
func _doc_korean_lines(doc_path: String) -> Array:
	var doc := FileAccess.get_file_as_string(doc_path)
	var start := doc.find("## Script")
	var fence := doc.find("```", start)
	var block := doc.substr(fence + 3, doc.find("```", fence + 3) - fence - 3)
	var english := RegEx.create_from_string("\\s*\\([^)]*[A-Za-z][^)]*\\)")
	var speaker_line := RegEx.create_from_string("^(?:.*→\\s*)?\\s*(" + "|".join(ALL_SPEAKERS) + "):\\s+(.*)$")
	var lines := []
	for raw in block.split("\n"):
		var line: String = raw
		var m := speaker_line.search(line)
		if m != null:
			lines.append("%s|%s" % [m.get_string(1), english.sub(m.get_string(2), "", true).strip_edges()])
		elif line.strip_edges().begins_with("▸ "):
			var rest := line.strip_edges().substr(2).strip_edges().substr(1).strip_edges()
			if rest.begins_with("\"") and rest.ends_with("\""):
				rest = rest.substr(1, rest.length() - 2)
			lines.append("-|%s" % rest)
	return lines


func _file_korean_lines(path: String) -> Array:
	var lines := []
	var speaker := RegEx.create_from_string("^(" + "|".join(ALL_SPEAKERS) + "):\\s+(.*)$")
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line: String = raw.strip_edges()
		var m := speaker.search(line)
		if m != null:
			lines.append("%s|%s" % [m.get_string(1), m.get_string(2)])
		elif line.begins_with("- "):
			lines.append("-|%s" % line.substr(2).replace("\\:", ":"))
	return lines


func _verbatim(doc_path: String, dialogue_path: String, label: String, minimum: int) -> void:
	var doc_lines := _doc_korean_lines(doc_path)
	var file_lines := _file_korean_lines(dialogue_path)
	check(doc_lines.size() >= minimum, "%s: found the doc's Korean lines (%d)" % [label, doc_lines.size()])
	var missing := doc_lines.filter(func(l): return not file_lines.has(l))
	var extra := file_lines.filter(func(l): return not doc_lines.has(l))
	check(missing.is_empty(), "%s: every Korean line in the doc appears verbatim %s" % [label, str(missing)])
	check(extra.is_empty(), "%s: no Korean line the doc lacks %s" % [label, str(extra)])
	check(doc_lines.size() == file_lines.size(), "%s: same number of lines (%d doc, %d file)" % [label, doc_lines.size(), file_lines.size()])


func _test_3b_files() -> void:
	print("scene_02.dialogue and optional_sat.dialogue")
	for path in [SCENE2_DIALOGUE, OC_DIALOGUE]:
		var text := FileAccess.get_file_as_string(path)
		var result: DMCompilerResult = DMCompiler.compile_string(text, path)
		check(text != "" and result.errors.is_empty(), "%s compiles with Dialogue Manager (%d errors)" % [path.get_file(), result.errors.size()])
		check(not text.contains("GameState.add_ddeok") and not text.contains("GameState.damage"), "%s: only set_boss / add_nunchi / lose_secret" % path.get_file())
	var s2 = load(SCENE2_DIALOGUE)
	var oc = load(OC_DIALOGUE)
	check(s2.cues.has("a") and s2.cues.has("e_entrance") and s2.cues.has("e_gate") and s2.cues.has("e_tv"), "scene_02 cues: a, e_entrance, e_gate, e_tv")
	check(oc.cues.has("oc01") and oc.cues.has("oc02") and oc.cues.has("oc03"), "optional_sat cues: oc01, oc02, oc03")
	var s2_text := FileAccess.get_file_as_string(SCENE2_DIALOGUE)
	check(s2_text.contains("GameState.lose_secret(\"our_home\", \"hyunjeong\")") and s2_text.contains("GameState.set_boss(\"eunju\")"), "1B tells 현정 (not 은주); the boss is 은주")
	# The form's printed lines are the doc's.
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenes/scene_02.json"))
	var doc := FileAccess.get_file_as_string(SCENE2_DOC)
	var form_ok := true
	for line in cfg["form_lines"]:
		form_ok = form_ok and doc.contains("│   %s" % line)
	check(form_ok and cfg["form_lines"].size() == 6, "the form shows the doc's 6 printed lines")
	_verbatim(SCENE2_DOC, SCENE2_DIALOGUE, "scene_02 vs doc", 40)
	_verbatim(OC_DOC, OC_DIALOGUE, "optional_sat vs doc", 15)
	# Speaker aliases are display only.
	check(FileAccess.get_file_as_string(SCENE2_DIALOGUE).contains("손미경: 은주아?"), "the script text keeps 손미경 / 손미숙")
	var aliases: Dictionary = load("res://scripts/dialogue_box.gd").load_aliases()
	check(aliases == {"손미숙": "미숙", "손미경": "미경"}, "alias table: 손미숙 -> 미숙, 손미경 -> 미경")


## Like _run_cue, plus a state snapshot each time a choice is asked and at the end.
func _run_cue_snaps(box: Node, res: Resource, cue: String, stub: RefCounted, picks: Array) -> Dictionary:
	var gs := _gs()
	var lines: Array = []
	var record := func(c: String, t: String): lines.append("%s: %s" % [c, t])
	box.line_shown.connect(record)
	var snaps: Array = []
	box.play(res, cue, [stub])
	var asked := 0
	var guard := 0
	while guard < 800:
		await process_frame
		guard += 1
		if box.choosing:
			snaps.append(_snapshot(gs))
			box.choose(picks[asked])
			asked += 1
		elif box.waiting:
			box.advance()
		elif not box.is_open:
			break
	snaps.append(_snapshot(gs))
	box.line_shown.disconnect(record)
	return {"lines": lines, "asked": asked, "snaps": snaps}


func _doc_choices_of(doc_path: String, from_marker: String, to_marker: String) -> Array:
	var points: Array = []
	var current: Array = []
	var lines := FileAccess.get_file_as_string(doc_path).split("\n")
	var on := false
	for i in lines.size():
		var line: String = lines[i]
		if line.begins_with(from_marker):
			on = true
		if to_marker != "" and line.begins_with(to_marker):
			break
		if not on:
			continue
		if line.begins_with("0") and line.contains("CHOICE"):
			current = []
			points.append(current)
		if line.begins_with("▸ "):
			var effect := ""
			for j in range(i + 1, mini(i + 3, lines.size())):
				if lines[j].strip_edges().begins_with("→"):
					effect = lines[j].strip_edges().substr(1).strip_edges()
					break
			current.append(effect)
	return points


## Checks one option's effect: exactly the one the doc names.
func _check_effect(label: String, effect: String, before: Dictionary, after: Dictionary, names: Dictionary) -> void:
	var keys := _changed_keys(before, after)
	if effect == "nothing":
		check(keys.is_empty(), label + ": changes nothing %s" % str(keys))
	elif effect.contains("눈치"):
		check(keys == ["nunchi"] and after["nunchi"] == before["nunchi"] + 1, label + ": +1 눈치 and nothing else %s" % str(keys))
	else:
		var card_name: String = effect.split("🔒")[1].strip_edges().split("  (")[0].strip_edges()
		var card: String = names.get(card_name, "?")
		var lost: Array = before["secrets_held"].filter(func(c): return not after["secrets_held"].has(c))
		var ok: bool = keys == ["secrets_held", "secrets_known_by"] and lost == [card] and after["secrets_held"].size() == before["secrets_held"].size() - 1
		check(ok, label + ": loses exactly %s %s" % [card, str(keys)])


func _test_scene2_effects() -> void:
	print("Scene 02 and OC-02 choice effects")
	var gs := _gs()
	var res = load(SCENE2_DIALOGUE)
	var oc = load(OC_DIALOGUE)
	var names := _card_ids_by_name()
	var points := _doc_choices_of(SCENE2_DOC, "02-B", "02-E")
	check(points.size() == 3 and points[0].size() == 3 and points[1].size() == 3 and points[2].size() == 3, "the doc has 3 choice points with 3 options each (9 options)")
	var box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(box)
	await _frames(2)
	for k in points.size():
		for i in points[k].size():
			gs.new_game()
			var stub := Stage3bStub.new()
			var picks := [2, 2, 2]
			picks[k] = i
			var ran := await _run_cue_snaps(box, res, "a", stub, picks)
			var snaps: Array = ran["snaps"]
			check(ran["asked"] == 3 and snaps.size() == 4, "02 choice %d option %d: all 3 choices asked" % [k + 1, i + 1])
			_check_effect("02 choice %d option %d (%s)" % [k + 1, i + 1, points[k][i]], points[k][i], snaps[k], snaps[k + 1], names)
	# OC-02: 3 options.
	var oc_points := _doc_choices_of(OC_DOC, "OC-02", "OC-03")
	check(oc_points.size() == 0 or oc_points[0].size() == 3, "(doc parse) OC-02 has 3 options")
	var oc_effects := ["+1 👀 눈치", "−1 🔒 자존심", "nothing"]
	for i in 3:
		gs.new_game()
		var ran := await _run_cue_snaps(box, oc, "oc02", Stage3bStub.new(), [i])
		check(ran["snaps"].size() == 2, "OC-02 option %d: one choice asked" % [i + 1])
		_check_effect("OC-02 option %d (%s)" % [i + 1, oc_effects[i]], oc_effects[i], ran["snaps"][0], ran["snaps"][1], names)
		if i == 1:
			check(gs.knows("banjang", "pride") and not gs.knows("eunju", "pride"), "OC-02 B: 자존심 is known by 반장, not 은주")
	gs.new_game()
	box.queue_free()
	await _frames(1)


func _test_scene2_paths() -> void:
	print("Scene 02 paths and taunts")
	var gs := _gs()
	var res = load(SCENE2_DIALOGUE)
	var box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(box)
	await _frames(2)
	# The +1 option at each point: 02-B A, 02-C B, 02-D B.
	gs.new_game()
	await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [0, 1, 1])
	check(gs.nunchi == 3 and gs.secrets_held.size() == gs.hand.size(), "the max 눈치 path (A, B, B) gives +3 and loses nothing")
	# 1B: 현정 and her mother know our_home; 은주 does not.
	gs.new_game()
	await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [1, 1, 2])
	check(gs.knows("hyunjeong", "our_home") and gs.knows("hyunjeong_mom", "our_home") and not gs.knows("eunju", "our_home"), "1B: our_home is known by hyunjeong and hyunjeong_mom, not eunju")
	check(gs.current_boss == "eunju", "the boss is eunju")
	# Taunts: only for the cards 은주 knows.
	var taunts := {
		"dad_country": ["손미숙: 너희 아빠도 와?", "손미경: 아프리카 사람 진짜 보고 싶다!"],
		"dad_drinking": ["은주: 너희 아빠는 오지 마. 소주 세 병 마시잖아."],
		"mom_salary": ["은주: 선물은 엄마 월급으로 사 와. 많이 번다며?"],
		"pride": ["은주: 올 때 존댓말 잊지 마."],
	}
	var all_taunts := []
	for card in taunts:
		all_taunts.append_array(taunts[card])
	gs.new_game()
	var none := await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [2, 1, 2])
	check(all_taunts.filter(func(l): return none["lines"].has(l)).is_empty(), "no card known to 은주: no taunts")
	for card in taunts:
		gs.new_game()
		gs.lose_secret(card, "eunju")
		var ran := await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [2, 1, 2])
		var shown: Array = all_taunts.filter(func(l): return ran["lines"].has(l))
		check(shown == taunts[card], "only %s known: only its taunt(s) %s" % [card, str(shown)])
	gs.new_game()
	for card in taunts:
		gs.lose_secret(card, "eunju")
	var every := await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [2, 1, 2])
	check(all_taunts.filter(func(l): return every["lines"].has(l)).size() == all_taunts.size(), "all four known: all taunts")
	# Taunts do not depend on who told: 1B's card is known by 현정, so no our_home taunt exists at all.
	gs.new_game()
	await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [1, 1, 2])
	check(gs.knows("hyunjeong", "our_home"), "(sanity) 1B leak data applied")
	# 자존심 lost in 02-C is known by 은주 and taunted at the end.
	gs.new_game()
	var lost_pride := await _run_cue_snaps(box, res, "a", Stage3bStub.new(), [2, 0, 2])
	check(lost_pride["lines"].has("은주: 올 때 존댓말 잊지 마.") and gs.knows("eunju", "pride"), "자존심 lost in 02-C: 은주 taunts it")
	# Speaker aliases show on the panel.
	check(box.display_name("손미숙·손미경") == "미숙·미경" and box.display_name("손미경") == "미경" and box.display_name("은주") == "은주", "speaker labels: 손미숙·손미경 shows as 미숙·미경 (display only)")
	gs.new_game()
	box.queue_free()
	await _frames(1)


func _write_progress_save(step: String, day: String, talked: Array = []) -> void:
	var save := make_gs()
	DirAccess.make_dir_recursive_absolute(WORLD_SAVE_DIR)
	save.save_path = WORLD_SAVE_DIR + "/save.json"
	save.set_progress(step)
	save.map_day = day
	for t in talked:
		save.mark_talked(t)
	save.save_game()
	save.free()


func _finish_box(world: Node) -> void:
	var guard := 0
	while world.dialogue_box.is_open and guard < 600:
		if world.dialogue_box.waiting:
			world.dialogue_box.advance()
		elif world.dialogue_box.choosing:
			world.dialogue_box.choose(0)
		await _frames(1)
		guard += 1
	await _frames(2)


func _await_box(world: Node) -> bool:
	var guard := 0
	while not world.dialogue_box.is_open and guard < 120:
		await _frames(1)
		guard += 1
	return world.dialogue_box.is_open


func _test_scene2_flow() -> void:
	print("Scene 02 flow and the walk home")
	var gs := _gs()
	var d: Node
	var world: Node
	# The date card leads into Scene 02 (covered with Saturday's end); here: from a save.
	_write_progress_save("scene_02", "mon")
	world = await _start_world(true, true)
	d = world.director
	check(await _await_box(world), "scene_02: the dialogue opens after the fade")
	check(d.phase == "s2" and world.player.movement_locked and gs.map_day == "mon" and gs.progress == "scene_02", "scene_02: movement locked, map_day mon")
	check(is_equal_approx(world.player.position.x, 4.5) and world.room_id == "classroom_1_3", "보람 sits at her desk in 1학년 3반")
	check(d.actors.size() == 7 and d.hyunjeong != null and d.hyunjeong.display_name == "현정", "placeholder actors: 현정 + 7 others (은주, 미숙, 미경, 박철수, 오동진, 최은주, 한은주)")
	var cast := []
	for a in d.actors.values():
		cast.append(a.display_name)
	cast.append(d.hyunjeong.display_name)
	cast.sort()
	var want := ["미경", "미숙", "박철수", "오동진", "은주", "최은주", "한은주", "현정"]
	want.sort()
	check(cast == want, "the cast labels match Scene 01's (미숙, 미경, 박철수, 오동진, 은주, 최은주, 한은주) plus 현정")
	check(FileAccess.file_exists(gs.save_path), "scene_02 autosaved")
	# The form appears for 02-D and goes after it.
	var saw_form := false
	var picks := [2, 2, 2]
	var guard := 0
	var asked := 0
	while world.dialogue_box.is_open and guard < 800:
		if world.dialogue_box.waiting:
			world.dialogue_box.advance()
		elif world.dialogue_box.choosing:
			world.dialogue_box.choose(picks[asked])
			asked += 1
		saw_form = saw_form or d.has_form()
		await _frames(1)
		guard += 1
	await _frames(6)
	check(saw_form and not d.has_form() and asked == 3, "the 02-D form was drawn during 02-D and is gone after")
	check(d.phase == "walk" and gs.progress == "mon_walk" and not world.player.movement_locked, "02-E: progress mon_walk, movement unlocked")
	var saved := make_gs()
	saved.save_path = gs.save_path
	check(saved.load_game() == OK and saved.progress == "mon_walk" and saved.map_day == "mon", "mon_walk is autosaved")
	saved.free()
	check(d.hyunjeong != null and d.hyunjeong.get_parent() == world.room and d.actors.is_empty(), "현정 waits at the classroom door; the rest of the class is gone")
	await _stop_world(world)

	# The walk: 현정 follows across every room change; triggers fire once, in order.
	_write_progress_save("mon_walk", "mon")
	world = await _start_world(true, true)
	d = world.director
	var lines := []
	world.dialogue_box.line_shown.connect(func(c: String, t: String): lines.append("%s: %s" % [c, t]))
	check(d.phase == "walk" and not world.player.movement_locked, "mon_walk resume: free to move")
	check(d.next_trigger() == "entrance", "the first trigger is the 현관")
	var hops := [
		["To_hallway_1f", "hallway_1f"], ["To_stairs", "stairs"], ["To_hallway_2f", "hallway_2f"],
		["To_stairs", "stairs"], ["To_hallway_1f", "hallway_1f"], ["To_entrance", "entrance"],
	]
	var follows := true
	for hop in hops:
		await _confirm_at(world, world.room.get_node(hop[0]))
		await _frames(3)
		if world.dialogue_box.is_open:
			await _finish_box(world)
		var h: Node3D = d.hyunjeong
		var here: bool = world.room_id == hop[1] and h != null and is_instance_valid(h) and h.get_parent() == world.room
		var near: bool = here and absf(h.position.x - world.player.position.x) < 2.0
		follows = follows and here and near
		check(here and near, "현정 follows to %s, beside the arrival door" % hop[1])
	check(follows and world.room_id == "entrance", "(summary) 현정 followed across 6 room changes, 2층 detour included")
	check(lines == ["현정: 토요일에 나도 가. 같이 가자."] and d.fired.has("entrance"), "entering the 현관 fired the first line, once (%s)" % str(lines))
	# Follow tick: she closes the distance.
	world.player.place(world.player.position.x + 5.0, 0)
	d._follow_tick(3.0)
	check(absf(d.hyunjeong.position.x - world.player.position.x) <= 1.51, "현정 stays about 1.5 behind (%.2f)" % absf(d.hyunjeong.position.x - world.player.position.x))
	# Leaving and coming back does not fire it again.
	await _confirm_at(world, world.room.get_node("To_hallway_1f"))
	await _frames(3)
	await _confirm_at(world, world.room.get_node("To_entrance"))
	await _frames(5)
	check(lines.size() == 1 and not world.dialogue_box.is_open, "re-entering the 현관 does not repeat the line")
	check(d.next_trigger() == "gate", "next trigger: the 교문")
	await _confirm_at(world, world.room.get_node("To_playground"))
	await _frames(3)
	await _confirm_at(world, world.room.get_node("To_gate"))
	await _frames(3)
	await _finish_box(world)
	check(lines.size() == 2 and lines[1] == "현정: 근데… 은주네 집에 반주기 있대. 노래 시킬 거야." and d.fired.has("gate"), "reaching the 교문 fires the second line")
	await _confirm_at(world, world.room.get_node("To_playground"))
	await _frames(3)
	await _confirm_at(world, world.room.get_node("To_gate"))
	await _frames(5)
	check(lines.size() == 2, "the 교문 line fires once")
	await _confirm_at(world, world.room.get_node("To_alley"))
	await _frames(5)
	check(world.room_id == "alley" and d.next_trigger() == "tv" and lines.size() == 2, "in the 골목길: only the TV trigger is left")
	check(world.room.get_node_or_null("TV") != null, "the 골목길 has a TV prop")
	check(world.door_locked(world.room.get_node("To_stationery")), "the 문방구 door is locked before the TV line")
	# The 집 exit is inactive before mon_roam.
	var home: Node3D = world.room.get_node("To_home")
	world.player.place(home.position.x, 0)
	await _frames(3)
	await _press("confirm")
	check(world._text_open and world._text_label.text == world.HOME_LINE and gs.progress == "mon_walk", "the 집 exit does nothing before mon_roam")
	await _close_text(world)
	# Out of range, then within 3 units of the 전파사 door.
	var shop: Node3D = world.room.get_node("To_radio_shop")
	world.player.place(shop.position.x - 4.0, 0)
	await _frames(5)
	check(not world.dialogue_box.is_open and not d.fired.has("tv"), "4 units from the 전파사 door: nothing yet")
	world.player.place(shop.position.x - 2.5, 0)
	await _frames(3)
	check(await _await_box(world), "within 3 units of the 전파사 door the TV line plays")
	await _finish_box(world)
	check(lines.size() == 3 and lines[2] == "문태식: …고 박뻥희 대통령의 국장은 오는 토요일에 거행됩니다.", "the anchor 문태식's line plays as dialogue")
	check(d.hyunjeong == null and not world.room.get_children().any(func(n): return n.has_method("walk_to") and n.visible), "현정 waved and went home")
	check(gs.progress == "mon_roam" and d.phase == "mon_roam" and not world.player.movement_locked, "progress mon_roam, movement free")
	check(not world.door_locked(world.room.get_node("To_stationery")), "the 문방구 door is open after the TV line")
	var after_tv := make_gs()
	after_tv.save_path = gs.save_path
	check(after_tv.load_game() == OK and after_tv.progress == "mon_roam", "mon_roam is autosaved")
	after_tv.free()
	# Monday's end: the 집 door.
	world.fade_time = 0.02
	world.title_hold = 0.3
	world.player.place(home.position.x, 0)
	await _frames(3)
	await _press("confirm")
	guard = 0
	while not world._title_label.visible and guard < 80:
		await process_frame
		guard += 1
	check(world._title_label.visible and world._title_label.text == "1979년 11월 3일 토요일" and world.player.movement_locked, "the title card shows 1979년 11월 3일 토요일")
	guard = 0
	while not world.end_card_shown and guard < 300:
		await process_frame
		guard += 1
	check(world.end_card_shown and world._end_label.visible and world._end_label.text == "[placeholder] END OF BUILD 3b", "the end card shows")
	check(gs.progress == "sat2_pending" and not world._title_label.visible and world.player.movement_locked, "progress sat2_pending, locked")
	var end_save := make_gs()
	end_save.save_path = gs.save_path
	check(end_save.load_game() == OK and end_save.progress == "sat2_pending", "sat2_pending is autosaved")
	end_save.free()
	await _stop_world(world)

	# Launching with sat2_pending shows the same end card.
	_write_progress_save("sat2_pending", "mon")
	world = await _start_world(true, true)
	check(world.end_card_shown and world._end_label.visible and world.player.movement_locked, "resume sat2_pending: the end card")
	await _stop_world(world)

	# mon_roam resume: the 문방구 door is open and the 집 door works.
	_write_progress_save("mon_roam", "mon")
	world = await _start_world(true, true)
	world._load_room("alley", "")
	check(world.director.phase == "mon_roam" and not world.door_locked(world.room.get_node("To_stationery")) and not world.door_locked(world.room.get_node("To_home")), "resume mon_roam: 문방구 and 집 doors open")
	world.fade_time = 0.0
	world.player.place(world.room.get_node("To_home").position.x, 0)
	await _frames(3)
	await _press("confirm")
	await _frames(3)
	check(gs.progress == "sat2_pending" and world.end_card_shown, "the 집 door ends Monday (no animation timing)")
	await _stop_world(world)

	# Saturday's 집 door and 문방구 are shut (sat_roam).
	_write_progress_save("sat_roam", "sat")
	world = await _start_world(true, true)
	world._load_room("alley", "")
	check(world.door_locked(world.room.get_node("To_stationery")) and world.door_locked(world.room.get_node("To_home")), "sat_roam: 문방구 and 집 doors are locked")
	await _stop_world(world)


func _test_resume_steps() -> void:
	print("Resume from each progress step")
	var gs := _gs()
	var want := {
		"scene_01": "a", "sat_roam": "f", "scene_02": "s2", "mon_walk": "walk", "mon_roam": "mon_roam", "mon": "s2",
	}
	for step in want:
		_write_progress_save(step, "sat" if step in ["scene_01", "sat_roam"] else "mon")
		var world: Node = await _start_world(true, true)
		if step in ["scene_01", "scene_02", "mon"]:
			await _await_box(world)
		await _frames(2)
		check(world.director.phase == want[step], "resume %s: phase %s (%s)" % [step, want[step], world.director.phase])
		check(world.room_id == "classroom_1_3", "resume %s: starts in 1학년 3반" % step)
		var day := "sat" if step in ["scene_01", "sat_roam"] else "mon"
		check(gs.map_day == day and world.layout.size() == 5, "resume %s: map_day %s, dealt" % [step, day])
		var locked: bool = step in ["scene_01", "scene_02", "mon"]
		check(world.player.movement_locked == locked, "resume %s: movement %s" % [step, "locked" if locked else "free"])
		if step == "mon":
			check(gs.progress == "scene_02", "resume mon: treated as the start of scene_02")
		await _stop_world(world)


func _test_scene2_death() -> void:
	print("Death in the Monday steps")
	var gs := _gs()
	for step in ["scene_02", "mon_walk", "mon_roam"]:
		_write_progress_save(step, "mon")
		var world: Node = await _start_world(true, true)
		await _frames(4)
		gs.add_nunchi(2)
		gs.lose_secret("pride", "eunju")
		gs.ddeok = 3
		gs.hearts_halves = 1
		gs.damage(1)
		await _frames(2)
		check(world._game_over, "%s: dying shows GAME OVER" % step)
		await _press("confirm")
		await _frames(4)
		check(world.room_id == "classroom_1_3" and is_equal_approx(world.player.position.x, 7.0), "%s: death restarts in 1학년 3반 at its door" % step)
		check(world.director.phase == "a" and gs.progress == "scene_01" and world.player.movement_locked, "%s: restarts at 01-A" % step)
		check(gs.nunchi == 0 and gs.ddeok == 0 and gs.secrets_held.size() == gs.hand.size() and gs.map_day == "sat" and gs.hearts_halves == gs.hearts_max_halves, "%s: fresh state, Saturday" % step)
		check(world.director.hyunjeong == null and world.director.fired.is_empty() and not world.director.has_form(), "%s: no 현정, no triggers, no form left" % step)
		await _stop_world(world)


func _test_optional_conversations() -> void:
	print("Optional conversations")
	var gs := _gs()
	_write_progress_save("sat_roam", "sat")
	var world: Node = await _start_world(true, true)
	var lines := []
	world.dialogue_box.line_shown.connect(func(c: String, t: String): lines.append("%s: %s" % [c, t]))
	# OC-01 in the 운동장: two actors, a talk spot with no body and no label.
	world._load_room("playground", "")
	var talkers: Array = world.room.get_children().filter(func(n): return n.has_meta("oc"))
	var talk_spots: Array = world.room.get_children().filter(func(n): return n.has_meta("talk_id"))
	check(talkers.size() == 2 and talk_spots.size() == 1, "OC-01: 박철수 and 오동진 and one talk spot in the 운동장")
	var oc01_names: Array = talkers.map(func(n): return n.display_name)
	oc01_names.sort()
	check(oc01_names == ["박철수", "오동진"], "OC-01 actors are 박철수 and 오동진")
	var spot: Node3D = talk_spots[0]
	check(spot.find_children("*", "MeshInstance3D", true, false).is_empty() and spot.find_children("*", "Label3D", true, false).is_empty(), "the talk spot has no marker (no body, no label)")
	var before := _snapshot(gs)
	world.player.place(spot.position.x, 0)
	# The overlap registers on a physics tick and World's _process (the keycap) runs one
	# step behind Player's, so a fixed frame count raced them; wait for the overlap, then
	# give the keycap its frames.
	var waited := 0
	while world.player.current_interactable != spot and waited < 60:
		await _frames(1)
		waited += 1
	await _frames(2)
	check(world.player.current_interactable == spot and world.key_prompt.visible, "standing at the talkers shows the usual Enter keycap")
	await _press("confirm")
	check(await _await_box(world), "Enter starts OC-01")
	await _finish_box(world)
	check(lines.size() == 6 and lines[0] == "철수: 넘어갔다! 내 꺼야." and lines[5] == "동진: …딱지나 해.", "OC-01 plays its 6 lines")
	check(gs.has_talked("oc01_dakji_sat"), "OC-01 is marked as talked")
	var diff := _changed_keys(before, _snapshot(gs))
	check(diff == ["talked"], "OC-01 changes nothing but the talked list %s" % str(diff))
	# Repeat: one line, no effect.
	before = _snapshot(gs)
	await _press("confirm")
	check(world._text_open and world._text_label.text == "[placeholder] repeat line" and not world.dialogue_box.is_open, "the repeat is a single placeholder line")
	await _close_text(world)
	check(_changed_keys(before, _snapshot(gs)).is_empty(), "the repeat has no effect")

	# OC-02 by the 신발장: a separate actor; the search spot still works.
	world._load_room("entrance", "")
	var rack: Node3D = world.room.get_node("ShoeRack")
	var sang: Array = world.room.get_children().filter(func(n): return n.has_meta("oc") and n.display_name == "상훈")
	check(sang.size() == 1, "OC-02: 상훈 stands in the 현관")
	check(sang[0] != rack and abs(sang[0].position.x - rack.position.x) < 3.0, "상훈 is beside the 신발장 (a separate actor)")
	world.player.place(rack.position.x, 0)
	await _frames(3)
	check(world.player.current_interactable == rack, "the 신발장 is still the nearest spot at its own position")
	world.layout = {}
	await _press("confirm")
	check(world._text_open and world._text_label.text == world.spawn_config["lines"]["empty"], "the 신발장 search still works")
	await _close_text(world)
	var talk2: Node3D = world.room.get_children().filter(func(n): return n.has_meta("talk_id"))[0]
	lines.clear()
	var nunchi_before: int = gs.nunchi
	world.player.place(talk2.position.x, 0)
	await _frames(3)
	await _press("confirm")
	check(await _await_box(world), "Enter starts OC-02")
	var guard := 0
	while not world.dialogue_box.choosing and guard < 100:
		if world.dialogue_box.waiting:
			world.dialogue_box.advance()
		await _frames(1)
		guard += 1
	check(world.dialogue_box.choosing and world.dialogue_box._rows.size() == 3, "OC-02 asks with 3 options")
	world.dialogue_box.choose(0)
	await _finish_box(world)
	check(gs.nunchi == nunchi_before + 1 and gs.has_talked("oc02_sangun_sat"), "OC-02 A: +1 눈치, stakes marked (oc02_sangun_sat)")
	# Stakes pay out once.
	await _press("confirm")
	check(world._text_open and world._text_label.text == "[placeholder] repeat line" and gs.nunchi == nunchi_before + 1, "OC-02 again: the repeat line, no second +1")
	await _close_text(world)
	var again := make_gs()
	again.save_path = gs.save_path
	world.autosave()
	check(again.load_game() == OK and again.has_talked("oc02_sangun_sat"), "the talked flag is saved (once per save)")
	again.free()

	# OC-03 in the 교무실.
	world._load_room("office", "")
	var teacher: Array = world.room.get_children().filter(func(n): return n.has_meta("oc"))
	check(teacher.size() == 1 and teacher[0].display_name == "오경자", "OC-03: 오경자 in the 교무실")
	lines.clear()
	var t3: Node3D = world.room.get_children().filter(func(n): return n.has_meta("talk_id"))[0]
	world.player.place(t3.position.x, 0)
	await _frames(3)
	await _press("confirm")
	await _await_box(world)
	await _finish_box(world)
	check(lines.size() == 3 and lines[2] == "오경자: …가정통신문은 엄마한테 드려라. 알았지?", "OC-03 plays its 3 lines")
	await _stop_world(world)

	# Only while progress is sat_roam.
	for step in ["scene_01", "scene_02", "mon_walk", "mon_roam"]:
		_write_progress_save(step, "sat" if step == "scene_01" else "mon")
		world = await _start_world(true, true)
		await _frames(3)
		for room_name in ["playground", "entrance", "office"]:
			world._load_room(room_name, "")
		var any := false
		for room_name in ["playground", "entrance", "office"]:
			world._load_room(room_name, "")
			any = any or world.room.get_children().any(func(n): return n.has_meta("oc") or n.has_meta("talk_id"))
		check(not any, "%s: no optional conversations in the rooms" % step)
		await _stop_world(world)
	# A save with the talks already done: every conversation is the repeat line.
	_write_progress_save("sat_roam", "sat", ["oc01_dakji_sat", "oc02_sangun_sat", "oc03_teacher_sat"])
	world = await _start_world(true, true)
	world._load_room("entrance", "")
	var spot2: Node3D = world.room.get_children().filter(func(n): return n.has_meta("talk_id"))[0]
	var before2 := _snapshot(gs)
	world.player.place(spot2.position.x, 0)
	await _frames(3)
	await _press("confirm")
	check(world._text_open and world._text_label.text == "[placeholder] repeat line" and not world.dialogue_box.is_open, "after load, a done conversation is the repeat line")
	check(_changed_keys(before2, _snapshot(gs)).is_empty(), "the repeat after load has no effect")
	await _stop_world(world)


func _test_polish() -> void:
	print("Polish: titles, labels, panel, pacing")
	var gs := _gs()
	var world: Node = await _start_world()
	var gone := true
	for id in world.rooms:
		world._load_room(id, "")
		var titles: Array = world.room.find_children("Title", "Label3D", true, false)
		gone = gone and titles.is_empty()
	check(gone, "no room has the big centered title")
	# Dev labels: on by default, F9 and the helper toggle them, they stay off across rooms.
	world._load_room("classroom_1_3", "")
	var labels := get_nodes_in_group("dev_labels")
	check(labels.size() > 3 and labels.all(func(l): return l.visible), "labels are on by default (%d labels)" % labels.size())
	check(world.labels_visible, "labels_visible defaults to true")
	var key := InputEventKey.new()
	key.keycode = KEY_F9
	key.pressed = true
	Input.parse_input_event(key)
	await _frames(3)
	check(not world.labels_visible and get_nodes_in_group("dev_labels").all(func(l): return not l.visible), "F9 hides every label")
	world._load_room("hallway_1f", "")
	check(get_nodes_in_group("dev_labels").all(func(l): return not l.visible), "labels stay off in the next room")
	world.toggle_labels()
	check(world.labels_visible and get_nodes_in_group("dev_labels").all(func(l): return l.visible), "toggling again shows them")
	var WorldScript = load("res://scripts/world.gd")
	check(WorldScript.parse_launch_args(PackedStringArray(["--no-labels"]))["no_labels"] and not WorldScript.parse_launch_args(PackedStringArray([]))["no_labels"], "--no-labels is parsed (default: labels on)")
	check(WorldScript.parse_launch_args(PackedStringArray(["--capture-alley"]))["capture_alley"], "--capture-alley is parsed")
	# Actor labels at different heights.
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenes/scene_01.json"))
	check(cfg["fade_in_hold"] == 1.5 and cfg["teacher_walk_seconds"] == 2.5 and cfg["first_line_delay"] == 1.0, "Scene 01 pacing tunables: 1.5 s, 2.5 s, 1.0 s")
	await _stop_world(world)

	# The panel fits its content; the choice column is compact.
	var res = load(DIALOGUE_PATH)
	var box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(box)
	await _frames(2)
	box.play(res, "a3", [Stage3bStub.new()])
	await _frames(6)
	var panel: Control = box.get_node("Root/Stack/Panel")
	check(panel.visible and panel.size.y > 40.0 and panel.size.y < 170.0, "the panel fits a 1-line message (%.0f px high)" % panel.size.y)
	var guard := 0
	while not box.choosing and guard < 60:
		if box.waiting:
			box.advance()
		await _frames(1)
		guard += 1
	await _frames(3)
	var column: Control = box.get_node("Root/Stack/Choices")
	var screen_h: float = box.get_node("Root").size.y
	check(box.choosing and column.size.y > 0.0 and column.size.y <= screen_h / 3.0, "the 4-option column is at most a third of the screen (%.0f of %.0f px)" % [column.size.y, screen_h])
	check(column.global_position.y + column.size.y <= panel.global_position.y + 1.0, "the choice column sits above the panel")
	var one_line_h: float = panel.size.y
	box.cancel()
	box.queue_free()
	await _frames(1)
	# A 2-line message grows the panel a little, not to a fixed block.
	var long_box: Node = load(DIALOGUE_BOX_PATH).instantiate()
	root.add_child(long_box)
	await _frames(2)
	long_box.get_node("Root/Stack/Panel/Box/Line").text = "가".repeat(120)
	long_box.visible = true
	long_box.get_node("Root/Stack/Panel").visible = true
	await _frames(4)
	var long_h: float = long_box.get_node("Root/Stack/Panel").size.y
	check(long_h > one_line_h and long_h < 260.0, "a 2-line message makes the panel taller (%.0f px)" % long_h)
	long_box.queue_free()
	await _frames(1)

	# Scene 01 pacing in real time: hold 1.5 s, teacher 2.5 s, first line 1.0 s after she starts.
	gs.new_game()
	_clean_world_saves()
	gs.save_path = WORLD_SAVE_DIR + "/save.json"
	var timed: Node = load("res://scenes/map_01.tscn").instantiate()
	timed.begin_progress = true
	root.add_child(timed)
	timed.fade_time = 0.0
	var started := Time.get_ticks_msec()
	var first_seen := [-1.0]
	var teacher_gone_at := -1.0
	timed.dialogue_box.line_shown.connect(func(_c, _t): if first_seen[0] < 0.0: first_seen[0] = (Time.get_ticks_msec() - started) / 1000.0)
	guard = 0
	while (teacher_gone_at < 0.0 or first_seen[0] < 0.0) and guard < 1200:
		await process_frame
		guard += 1
		if timed.dialogue_box.waiting:
			timed.dialogue_box.advance()
		var teacher = timed.director.actors.get("teacher")
		if teacher != null and is_instance_valid(teacher) and not teacher.visible:
			teacher_gone_at = (Time.get_ticks_msec() - started) / 1000.0
	var first_line_at: float = first_seen[0]
	check(first_line_at >= 2.4 and first_line_at <= 3.6, "the boys' first line comes 1.0 s after the 1.5 s hold, while the teacher walks (%.2f s)" % first_line_at)
	check(teacher_gone_at >= 3.9 and teacher_gone_at <= 5.0, "the teacher's walk out takes 2.5 s after the 1.5 s hold (gone at %.2f s)" % teacher_gone_at)
	await _stop_world(timed)
	_clean_world_saves()


# ── Build 3c: keycap, door clearance, 빈 교실, import ──────────────────

const TuningScript := preload("res://scripts/tuning.gd")
const DIALOGUE_DIR := "res://data/dialogue"
## A prop whose underside is this high hangs on the wall; it cannot block the floor.
const OVERHEAD := 1.0
const BODY_HALF := 0.25


func _test_keycap() -> void:
	print("Interaction keycap")
	var world: Node = await _start_world()
	await _confirm_at(world, world.room.get_node("To_classroom_1_3"))
	var player: Node3D = world.player
	check(player.find_children("*", "Label3D", true, false).is_empty() and player.get_node_or_null("Prompt") == null, "nothing floats above 보람: no label under the player")
	var keycap: Node3D = world.key_prompt
	check(keycap != null and keycap.get_parent() == world.room, "the keycap belongs to the room, not the player")
	check(keycap.get_node("KeyText").text == "Enter", "the keycap says Enter")
	var stove: Node3D = world.room.get_node("Stove")
	player.place(stove.position.x, 0)
	await _frames(3)
	check(player.current_interactable == stove and keycap.visible, "free at the stove: the keycap shows")
	check(is_equal_approx(keycap.global_position.x, stove.global_position.x) and keycap.global_position.y > stove.size.y, "the keycap hovers above the stove")
	# Nearest wins: next to the 교탁 the closer one gets the cap.
	var lectern: Node3D = world.room.get_node("Lectern")
	player.place(lectern.position.x + 0.3, 0)
	await _frames(3)
	check(player.current_interactable == lectern and is_equal_approx(keycap.global_position.x, lectern.global_position.x), "the keycap follows the nearest interactable")
	# Locked (text open, scene, transition...): hidden at once.
	player.movement_locked = true
	await _frames(2)
	check(not keycap.visible, "movement locked: the keycap is hidden")
	player.movement_locked = false
	await _frames(2)
	check(keycap.visible, "movement free again: the keycap is back")
	await _press("confirm")
	check(world.text_is_open() and not keycap.visible, "while the text box is open the keycap is hidden")
	await _press("confirm")
	# Doors get one too, above the door.
	var door: Node3D = world.room.get_node("To_hallway_1f")
	player.place(door.position.x, 0)
	await _frames(3)
	check(keycap.visible and keycap.global_position.y > door.size.y, "the keycap hovers above a door")
	# Away from everything: gone.
	player.place(-4.5, 0)
	await _frames(3)
	check(not keycap.visible, "no keycap away from anything")
	# A new room gets its own keycap.
	player.place(door.position.x, 0)
	await _frames(3)
	await _press("confirm")
	await _wait_transition(world)
	await _frames(3)
	check(world.key_prompt != null and is_instance_valid(world.key_prompt) and world.key_prompt.get_parent() == world.room and world.key_prompt.visible, "the next room has its keycap, shown at the arrival door")
	await _stop_world(world)


## Everything that stands on the floor of a room, as {name, lo, hi, z0, z1}.
func _floor_things(room: Node, room_id: String) -> Array:
	var things := []
	for c in room.get_children():
		if c.has_method("is_door") or c.has_method("is_spawn_point") or not ("size" in c):
			continue
		if "elevation" in c and c.elevation >= OVERHEAD:
			continue
		things.append({"name": str(c.name), "lo": c.position.x - c.size.x / 2.0, "hi": c.position.x + c.size.x / 2.0,
				"z0": c.position.z - c.size.z / 2.0, "z1": c.position.z + c.size.z / 2.0})
	# Scene actors and talk spots are placed from data, not in the room scene.
	# (Not checked: 현정 waiting at the door and following 보람, and 선생님 leaving by it; those are meant to be there.)
	for path in ["res://data/scenes/scene_01.json", "res://data/scenes/scene_02.json"]:
		var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		if cfg["room"] != room_id:
			continue
		for id in cfg["actors"]:
			var a: Dictionary = cfg["actors"][id]
			things.append({"name": "%s actor %s" % [path.get_file(), id], "lo": a["x"] - BODY_HALF, "hi": a["x"] + BODY_HALF,
					"z0": a["z"] - BODY_HALF, "z1": a["z"] + BODY_HALF})
	var optional: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenes/optional_sat.json"))
	for id in optional["conversations"]:
		var oc: Dictionary = optional["conversations"][id]
		if oc["room"] != room_id:
			continue
		things.append({"name": "%s talk spot" % id, "lo": oc["x"] - oc["size"][0] / 2.0, "hi": oc["x"] + oc["size"][0] / 2.0,
				"z0": oc["z"] - oc["size"][2] / 2.0, "z1": oc["z"] + oc["size"][2] / 2.0})
		for a in oc["actors"]:
			var ax: float = oc["x"] + a["dx"]
			things.append({"name": "%s actor %s" % [id, a["name"]], "lo": ax - BODY_HALF, "hi": ax + BODY_HALF,
					"z0": a["z"] - BODY_HALF, "z1": a["z"] + BODY_HALF})
	return things


func _test_door_clearance() -> void:
	print("Doors stay clear")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP_DATA))
	var lanes := TuningScript.lane_config()
	var tested := 0
	for id in data["rooms"]:
		var room: Node = load(data["rooms"][id]).instantiate()
		var things := _floor_things(room, id)
		var bad := []
		for door in _door_list(room):
			# The reach zone is the door's width plus half a metre each side, at every depth.
			var reach_lo: float = door.position.x - (door.size.x + 1.0) / 2.0
			var reach_hi: float = door.position.x + (door.size.x + 1.0) / 2.0
			for t in things:
				if t["lo"] < reach_hi and reach_lo < t["hi"]:
					bad.append("%s in the reach of %s" % [t["name"], door.name])
		# Arrival points: nothing stands where 보람 appears.
		for spawn in room.get_children().filter(func(c): return c.has_method("is_spawn_point")):
			var z: float = room.lane_origin_z - spawn.lane * lanes["lane_spacing"]
			for t in things:
				if t["lo"] < spawn.position.x + BODY_HALF and spawn.position.x - BODY_HALF < t["hi"] and t["z0"] < z + BODY_HALF and z - BODY_HALF < t["z1"]:
					bad.append("%s on the arrival point %s" % [t["name"], spawn.name])
		check(bad.is_empty(), "%s: nothing in a door's reach zone or on an arrival point %s" % [id, str(bad)])
		tested += 1
		room.free()
	check(tested == data["rooms"].size(), "clearance checked in every registered room (%d)" % tested)
	# The case that started it: no desk in front of the 1학년 3반 door.
	var classroom: Node = load(data["rooms"]["classroom_1_3"]).instantiate()
	var door: Node3D = classroom.get_node("To_hallway_1f")
	var desks := classroom.get_children().filter(func(c): return str(c.name).begins_with("Desk"))
	check(desks.size() == 6 and desks.all(func(d): return absf(d.position.x - door.position.x) >= (door.size.x + 1.0) / 2.0 + d.size.x / 2.0), "1학년 3반: all six desks are clear of the door's reach")
	classroom.free()


func _test_empty_classroom() -> void:
	print("빈 교실 and the map")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP_DATA))
	check(data["rooms"].get("empty_classroom") == "res://maps/map_01/empty_classroom.tscn", "빈 교실 is in the registry")
	var lanes := TuningScript.lane_config()
	var scenes := {}
	for id in data["rooms"]:
		scenes[id] = load(data["rooms"][id]).instantiate()
	var empty: Node = scenes["empty_classroom"]
	var hall: Node = scenes["hallway_2f"]
	check(empty.room_id == "empty_classroom" and empty.room_title == "빈 교실", "빈 교실 has its id and title")
	var out: Node3D = empty.get_node_or_null("To_hallway_2f")
	var into: Node3D = hall.get_node_or_null("To_empty_classroom")
	check(out != null and out.target_room == "hallway_2f" and hall.get_spawn(out.target_spawn) != null, "a door from 빈 교실 back to the 2층 복도, with its spawn")
	check(into != null and into.target_room == "empty_classroom" and empty.get_spawn(into.target_spawn) != null, "a door from the 2층 복도 into 빈 교실, with its spawn")
	check(not out.locked and not into.locked, "neither door of 빈 교실 is locked itself")
	var names := empty.get_children().map(func(c): return str(c.name))
	check(names.has("OrganBody") and names.has("Blackboard") and names.has("StackedDesksA"), "빈 교실 has the 풍금, the 칠판 and stacked desks")
	check(empty.get_children().filter(func(c): return c.has_method("interact") and not c.has_method("is_door")).is_empty(), "no search spots or interactables in 빈 교실")
	# Same tuning as every other room: default shell, lanes inside the room.
	var defaults: Node = load("res://maps/room.tscn").instantiate()
	for id in scenes:
		var r: Node = scenes[id]
		var deepest: float = r.lane_origin_z - (lanes["lane_count"] - 1) * lanes["lane_spacing"]
		check(deepest > -r.depth, "%s: all %d lanes fit inside the room" % [id, lanes["lane_count"]])
	check(empty.depth == defaults.depth and empty.height == defaults.height and empty.lane_origin_z == defaults.lane_origin_z, "빈 교실 uses the default depth, height and lane origin")
	defaults.free()
	# Saturday: the 2층 stairs door is the only way up, and it is locked; Monday opens it.
	for day in ["sat", "mon"]:
		var open_doors: Array = data.get("day_unlocked", {}).get(day, [])
		var seen := {data["start_room"]: true}
		var queue: Array = [data["start_room"]]
		while not queue.is_empty():
			var here: String = queue.pop_front()
			for d in _door_list(scenes[here]):
				var key := "%s/%s" % [here, d.name]
				if d.locked and not open_doors.has(key):
					continue
				if not seen.has(d.target_room):
					seen[d.target_room] = true
					queue.append(d.target_room)
		if day == "sat":
			check(not seen.has("hallway_2f") and not seen.has("empty_classroom"), "Saturday: neither the 2층 복도 nor 빈 교실 can be reached")
		else:
			check(seen.has("hallway_2f") and seen.has("empty_classroom"), "Monday: both can be reached through the stairs door")
	for s in scenes.values():
		s.free()


func _test_3c_files() -> void:
	print("Build 3c: args, props")
	var WorldScript = load("res://scripts/world.gd")
	check(WorldScript.parse_launch_args(PackedStringArray(["--capture-rooms"]))["capture_rooms"] and not WorldScript.parse_launch_args(PackedStringArray([]))["capture_rooms"], "--capture-rooms is parsed")
	var dev: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--new-game", "--no-labels", "--seed", "4", "--skip-to", "mon_walk", "--hearts", "2.5"]))
	check(dev["new_game"] and dev["no_labels"] and dev["seed"] == 4 and dev["skip_to"] == "mon_walk" and dev["hearts_halves"] == 5, "the existing dev args still parse")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP_DATA))
	var expect := {
		"hallway_2f": ["Bulletin", "NationalCharter", "Window1", "StackedDesksA"],
		"stationery": ["Counter", "DakjiShelf", "JjondeugiShelf", "CrayonRack", "GachaBody"],
	}
	for id in expect:
		var room: Node = load(data["rooms"][id]).instantiate()
		var names := room.get_children().map(func(c): return str(c.name))
		check(expect[id].all(func(n): return names.has(n)), "%s has its dressing %s" % [id, str(expect[id])])
		room.free()
	# The dressing is plain props: no interactable was added, so the spot pool is unchanged.
	var spot_nodes := 0
	for id in data["rooms"]:
		var room: Node = load(data["rooms"][id]).instantiate()
		for c in room.get_children():
			if c.has_method("interact") and not c.has_method("is_door") and c.spot_id != "":
				spot_nodes += 1
		room.free()
	check(spot_nodes == 12, "still exactly 12 search-spot nodes in the rooms (%d)" % spot_nodes)


func _test_import_and_dialogue() -> void:
	print("Import: stale .dialogue and project.godot")
	for file_name in DirAccess.get_files_at(DIALOGUE_DIR):
		if file_name.get_extension() != "dialogue":
			continue
		var path := DIALOGUE_DIR.path_join(file_name)
		var import_path := path + ".import"
		check(FileAccess.file_exists(import_path), "%s has an .import file" % file_name)
		check(FileAccess.get_modified_time(path) <= FileAccess.get_modified_time(import_path), "%s is not newer than its .import (re-run godot --headless --import)" % file_name)
		var raw := FileAccess.get_file_as_string(path)
		var compiled: DMCompilerResult = DMCompiler.compile_string(raw, path)
		var imported = load(path)
		var same_content: bool = compiled.errors.is_empty() and imported != null \
				and var_to_str(imported.lines) == var_to_str(compiled.lines) \
				and var_to_str(imported.cues) == var_to_str(compiled.cues)
		check(same_content, "%s: the imported resource matches the raw text" % file_name)
	# --import must leave project.godot exactly as it was (the Dialogue Manager's
	# automatic translation-template update is switched off in project.godot).
	var project_path := ProjectSettings.globalize_path("res://project.godot")
	var before := FileAccess.get_file_as_bytes(project_path)
	check(ProjectSettings.get_setting("dialogue_manager/editor/translations/UPDATE_TRANSLATION_TEMPLATES_AUTOMATICALLY", true) == false, "the plugin's automatic POT update is off")
	var output := []
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--import", "--path", ProjectSettings.globalize_path("res://").trim_suffix("/")], output)
	var after := FileAccess.get_file_as_bytes(project_path)
	if after != before:
		var restore := FileAccess.open(project_path, FileAccess.WRITE)
		restore.store_buffer(before)
		restore.close()
	check(code == 0, "godot --headless --import exits cleanly (exit %d)" % code)
	check(after == before, "godot --headless --import leaves project.godot byte-identical")


# ── Build 4a: the fight player core ─────────────────────────────────────

const SONG_PATH := "res://data/songs/eunju_dalnim.json"
const SHEET_PATH := "res://docs/songs/songsheet-01-eunju-dalnim-v0.2.md"
const FIGHT_SAVE_DIR := "user://test_fight_saves"


## A clock that records what the fight asks of it (it only knows the interface).
class RecordingClock extends SongClock:
	var calls: Array[String] = []
	var pos := 0.0
	var running := false

	func play() -> void:
		calls.append("play")
		pos = 0.0
		running = true

	func pause() -> void:
		calls.append("pause")
		running = false

	func resume() -> void:
		calls.append("resume")
		running = true

	func seek(seconds: float) -> void:
		calls.append("seek")
		pos = seconds

	func tick(delta: float) -> void:
		if running:
			pos += delta

	func get_position() -> float:
		return pos

	func is_playing() -> bool:
		return running


func _has_hangul(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


func _strings_of(v: Variant, out: Array) -> void:
	if v is String:
		out.append(v)
	elif v is Array:
		for x in v:
			_strings_of(x, out)
	elif v is Dictionary:
		for k in v:
			_strings_of(k, out)
			_strings_of(v[k], out)


func _test_song_json() -> void:
	print("Song file vs song sheet")
	check(FileAccess.file_exists(SHEET_PATH), "the song sheet is in docs/songs")
	check(FileAccess.file_exists(SONG_PATH), "data/songs/eunju_dalnim.json exists")
	var sheet := SongSheet.parse(FileAccess.get_file_as_string(SHEET_PATH))
	check(sheet["errors"].is_empty(), "the song sheet parses (title, lyrics, anchor)")
	var song: Dictionary = SongData.load_file(SONG_PATH)
	check(not song.is_empty() and SongData.validate(song).is_empty(), "the song file validates")
	check(song["id"] == "eunju_dalnim" and song["boss"] == "eunju" and is_equal_approx(song["countdown"], 5.0), "id, boss, countdown 5.0")
	check(song["title"] == sheet["title"], "title matches the sheet")

	var blanks := SongData.flat_blanks(song)
	check(blanks.size() == 10, "10 blanks")
	var split := []
	for phase in song["phases"]:
		split.append(phase["blanks"].size())
	check(split == [3, 3, 2, 2] and song["phases"].size() == 4, "blanks split 3/3/2/2 across 4 phases")
	var sections := []
	for phase in song["phases"]:
		sections.append(phase["section"])
	check(sections == ["Verse", "Chorus", "Bridge", "Final chorus"], "phase sections")
	var lyric_of := {}
	for l in sheet["lyrics"]:
		if l["blank"] != 0:
			lyric_of[l["blank"]] = l
	for b in blanks:
		var n: int = b["n"]
		var doc: Dictionary = sheet["blanks"][n]
		check(b["options"].size() == 3 and b["options"].has(b["answer"]), "blank %d: 3 options, the answer is one of them" % n)
		check(b["options"] == doc["options"] and b["answer"] == doc["answer"], "blank %d: options and answer match the sheet" % n)
		check(b["line"] == lyric_of[n]["text"] and b["line"].contains("___") and b["line"].count("___") == 1, "blank %d: line matches the lyrics, one ___" % n)
		check(b["teaches"] == doc["teaches"], "blank %d: teaches matches" % n)
		check(b["phase"] == SongSheet.phase_of(doc["phase_name"]), "blank %d: phase matches" % n)
	check(blanks[4]["line"] == "밤마다 ___ 달을 먹어요?", "blank 5 keeps the edited line")

	# Lines: all of them, in order, with the spoken intro and outro.
	var lines: Array = song["lines"]
	check(lines.size() == sheet["lyrics"].size() and lines.size() == 21, "21 lines: 19 sung plus the spoken intro and outro")
	var same_lines := true
	for i in lines.size():
		var d: Dictionary = sheet["lyrics"][i]
		var speaker: String = "보람" if d["kind"] == "outro" else d["speaker"]  # the build_song.gd outro override
		if lines[i]["text"] != d["text"] or lines[i]["kind"] != d["kind"] or lines[i]["phase"] != d["phase"] \
				or lines[i].get("blank", 0) != d["blank"] or lines[i].get("speaker", "") != speaker:
			same_lines = false
	check(same_lines, "every line matches the sheet in order (text, kind, phase, blank, speaker)")
	check(lines[0]["kind"] == "intro" and lines[0]["text"] == "자, 다 조용히 해! 내 노래야!" and lines[0]["speaker"] == "은주", "spoken intro")
	check(lines[-1]["kind"] == "outro" and lines[-1]["text"] == "잘 먹겠습니다.", "spoken outro")
	var lyric_lines := lines.filter(func(l): return l["kind"] == "lyric")
	check(lyric_lines.size() == 19, "19 sung lines")
	var times_ok := true
	for i in range(1, lines.size()):
		if lines[i]["time"] < lines[i - 1]["time"]:
			times_ok = false
	check(times_ok, "line times never go backwards")
	var cfg: Dictionary = TuningScript.fight_config()
	var even := is_equal_approx(lines[1]["time"], cfg["first_line_time"])
	for i in range(2, lines.size()):
		even = even and is_equal_approx(lines[i]["time"] - lines[i - 1]["time"], cfg["line_gap"])
	check(even, "placeholder times are evenly spaced by tuning.json (first line %.1fs, gap %.1fs)" % [cfg["first_line_time"], cfg["line_gap"]])
	var blank_times_ok := true
	for b in blanks:
		for l in lines:
			if l.get("blank", 0) == b["n"] and not is_equal_approx(l["time"], b["time"]):
				blank_times_ok = false
	check(blank_times_ok, "a blank's time is its line's time")
	check(song["length"] > lines[-1]["time"], "the song is longer than its last line")

	# Attack and counter ids.
	var snake := RegEx.create_from_string("^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
	var ids := {}
	var ids_ok := true
	var reg := FightRegistry.new()
	for b in blanks:
		for key in ["attack", "counter"]:
			ids_ok = ids_ok and snake.search(b[key]) != null
			ids[b[key]] = true
		ids_ok = ids_ok and (b["counter"].ends_with("_slapstick") or b["counter"].ends_with("_gory")) and b["counter"].begins_with(b["attack"])
		ids_ok = ids_ok and not reg.attack(b["attack"])["placeholder"] and not reg.counter(b["counter"])["placeholder"]
	check(ids_ok, "attack and counter ids are snake_case, paired, and in the registry")
	check(ids.size() == 20, "20 distinct ids")
	check(reg.attack("no_such_attack")["placeholder"] and reg.counter("no_such_counter")["placeholder"], "an unknown id falls back to a placeholder")
	check(reg.attack("no_such_attack")["size"] is Vector3 and reg.counter("no_such_counter")["tone"] == "slapstick", "the fallback is usable")
	var gory := blanks.filter(func(b): return b["counter"].ends_with("_gory")).map(func(b): return int(b["n"]))
	check(gory == [7, 8, 9, 10], "bridge and final counters are gory (the sheet's 🩸), the rest slapstick")

	# Loaded blanks: stored, unused.
	check(song["loaded"].size() == 3, "three loaded cards stored")
	var loaded_ok := true
	for item in song["loaded"]:
		var match_doc := false
		for d in sheet["loaded"]:
			if d["blank"] == item["blank"] and d["extra_option"] == item["extra_option"]:
				match_doc = true
		loaded_ok = loaded_ok and match_doc and _gs().hand.has(item["card"])
	check(loaded_ok, "loaded: card ids are in the hand, blank numbers and extra options match the sheet")
	check(blanks.all(func(b): return b["options"].size() == 3), "the file's blanks all have 3 options (the extra option is added at play time)")

	# Game over anchor and outcomes.
	check(song["game_over"]["line"] == sheet["anchor"] and song["game_over"]["line"] == "오늘 저녁, 국민학교 1학년 장보람 양이 생일 파티에서 사망했습니다. 다음 소식입니다.", "game-over anchor line is verbatim")
	check(song["game_over"]["anchor"] == "문태식", "the anchor is 문태식")
	check(song["outcomes"].has("revenge") and song["outcomes"].has("survival"), "outcomes: revenge and survival placeholders")

	# Korean only from the sheet.
	var allowed := {"문태식": true}
	for l in sheet["lyrics"]:
		allowed[l["text"]] = true
		allowed[l["speaker"]] = true
	for n in sheet["blanks"]:
		var doc: Dictionary = sheet["blanks"][n]
		allowed[doc["teaches"]] = true
		allowed[doc["answer"]] = true
		for o in doc["options"]:
			allowed[o] = true
	for item in sheet["loaded"]:
		allowed[item["extra_option"]] = true
	allowed[sheet["title"]] = true
	allowed["보람"] = true  # the outro speaker override (build_song.gd)
	allowed[sheet["survival_line"]] = true
	for item in sheet["loaded"]:
		allowed[item["taunt"]] = true
	allowed[sheet["anchor"]] = true
	var all_strings := []
	_strings_of(song, all_strings)
	var stray := []
	for s in all_strings:
		if _has_hangul(s) and not allowed.has(s):
			stray.append(s)
	check(stray.is_empty(), "every Korean string in the song file is from the sheet %s" % str(stray))


func _test_song_clock() -> void:
	print("Song clock")
	var c: SongClock = SilentSongClock.new()
	check(not c.is_playing() and c.get_position() == 0.0, "starts stopped at 0")
	c.play()
	c.tick(1.5)
	check(c.is_playing() and is_equal_approx(c.get_position(), 1.5), "plays: tick advances the position")
	c.pause()
	c.tick(3.0)
	check(not c.is_playing() and is_equal_approx(c.get_position(), 1.5), "paused: the position holds")
	c.resume()
	c.tick(0.5)
	check(is_equal_approx(c.get_position(), 2.0), "resume continues from where it paused")
	c.seek(10.0)
	check(is_equal_approx(c.get_position(), 10.0), "seek")
	c.play()
	check(c.get_position() == 0.0, "play starts from the top")
	var source := FileAccess.get_file_as_string("res://scripts/fight.gd")
	check(source.find("AudioStream") == -1 and source.find("AudioServer") == -1, "no audio in the fight code")
	check(source.count("SilentSongClock") == 1, "the fight code names the silent clock once, as the default")


func _tiny_song(count: int) -> Dictionary:
	var blanks := []
	for i in count:
		blanks.append({"n": i + 1, "time": 1.0 + i, "line": "x ___", "options": ["a", "b", "c"], "answer": "a", "attack": "atk", "counter": "ctr"})
	return {"boss": "tiny", "phases": [{"phase": 1, "section": "Verse", "blanks": blanks}]}


func _right_all(logic: FightLogic) -> void:
	while logic.has_blank():
		logic.answer(logic.current()["answer"])


func _test_fight_logic() -> void:
	print("Fight logic: scoring, penalty, outcomes")
	var song: Dictionary = SongData.load_file(SONG_PATH)

	# Scoring.
	var gs := make_gs()
	gs.begin_fight("eunju")
	var logic := FightLogic.new(song, 5, gs)
	check(logic.total() == 10 and logic.score() == 0, "10 blanks, score 0 before any answer")
	var r1 := logic.answer(logic.current()["answer"])
	check(r1["right"] and gs.hearts_halves == 10 and logic.correct == 1, "a right answer costs nothing")
	logic.answer(logic.current()["options"][0] if logic.current()["options"][0] != logic.current()["answer"] else logic.current()["options"][1])
	check(gs.hearts_halves == 8 and logic.wrong == 1, "a wrong answer costs exactly 1 heart (2 halves)")
	var r3 := logic.answer("")
	check(r3["timeout"] and not r3["right"] and gs.hearts_halves == 6, "a timeout counts as wrong and costs 1 heart")
	check(logic.results[2]["timeout"] and logic.wrong == 2, "the timeout is recorded as wrong")
	while logic.has_blank():
		logic.answer(logic.current()["answer"])
	check(logic.correct == 8 and logic.score() == 80, "8 right of 10 = 80")
	gs.free()
	for case in [[3, 0, 100], [3, 1, 67], [3, 2, 33], [3, 3, 0], [7, 3, 57], [10, 5, 50]]:
		var g := make_gs()
		g.begin_fight("tiny")
		var lg := FightLogic.new(_tiny_song(case[0]), 1, g)
		lg.correct = case[0] - case[1]
		lg.index = case[0]
		check(lg.score() == case[2], "score for %d of %d right is round(100x/n) = %d" % [case[0] - case[1], case[0], case[2]])
		g.free()

	# Revenge: no damage.
	gs = make_gs()
	gs.damage(4)  # arrived hurt: 3 hearts
	gs.begin_fight("eunju")
	logic = FightLogic.new(song, 5, gs)
	_right_all(logic)
	check(logic.wrong == 0 and gs.hearts_halves == 6 and logic.outcome() == "revenge", "no wrong answers: revenge, no hearts lost")
	var res := logic.finish()
	check(res == {"score": 100, "outcome": "revenge"}, "revenge result is 100 / revenge")
	check(gs.hearts_halves == 10, "revenge restores hearts to full (5)")
	check(gs.outcomes["eunju"] == "revenge" and gs.scores["eunju"] == 100 and not gs.in_fight, "revenge and the score are saved in GameState, the fight is over")
	gs.free()

	# Revenge from full hearts leaves them at 5.
	gs = make_gs()
	gs.begin_fight("eunju")
	logic = FightLogic.new(song, 5, gs)
	_right_all(logic)
	logic.finish()
	check(gs.hearts_halves == 10 and gs.outcomes["eunju"] == "revenge", "revenge from full hearts: still 5")
	gs.free()

	# Survival: damage taken, at least half a heart left, nothing restored.
	gs = make_gs()
	gs.begin_fight("eunju")
	logic = FightLogic.new(song, 5, gs)
	while logic.has_blank():
		var n: int = logic.current()["n"]
		logic.answer("" if n % 3 == 0 else logic.current()["answer"])
	check(logic.wrong == 3 and gs.hearts_halves == 4 and not logic.lost() and logic.finished(), "3 wrong: 2 hearts left, still standing")
	check(logic.outcome() == "survival" and logic.score() == 70, "survival, 70")
	logic.finish()
	check(gs.hearts_halves == 4, "survival restores nothing")
	check(gs.outcomes["eunju"] == "survival" and gs.scores["eunju"] == 70, "survival and the score are saved")
	gs.free()

	# Survival on the last half heart.
	gs = make_gs()
	gs.damage(5)  # 5 halves
	gs.begin_fight("eunju")
	logic = FightLogic.new(song, 5, gs)
	var k := 0
	while logic.has_blank():
		logic.answer("" if k < 2 else logic.current()["answer"])
		k += 1
	check(gs.hearts_halves == 1 and not logic.lost() and logic.finish()["outcome"] == "survival", "half a heart left is still a survival win")
	gs.free()

	# Game over at 0 hearts: the fight game over, never the outside-fight death reset.
	gs = make_gs()
	gs.lose_secret("pride", "eunju")
	gs.set_progress("scene_09")
	gs.add_nunchi(3)
	gs.damage(8)  # 2 halves
	gs.begin_fight("eunju")
	var counts := watch(gs, ["fight_lost", "player_died", "state_reset"])
	logic = FightLogic.new(song, 5, gs)
	var over := logic.answer("")
	check(over["lost"] and gs.hearts_halves == 0 and logic.lost(), "the last heart gone: lost")
	check(counts["fight_lost"] == 1 and counts["player_died"] == 0 and counts["state_reset"] == 0, "in a fight, 0 hearts fires fight_lost, not player_died or a reset")
	check(gs.progress == "scene_09" and not gs.has_secret("pride") and gs.in_fight, "no death reset: progress and cards kept, still in the fight")
	check(not logic.finished() and logic.finish().is_empty() and gs.in_fight and not gs.outcomes.has("eunju"), "a lost fight records no win")
	# Retry: the snapshot comes back, the fight starts over, the options shuffle again.
	var first_order := []
	var second_order := []
	var fresh := FightLogic.new(song, 5, gs)
	for b in fresh.blanks:
		first_order.append(fresh.options_for(b))
	check(gs.retry_fight(), "retry_fight works after the loss")
	logic.restart(true)
	check(gs.hearts_halves == 2 and gs.nunchi == 3, "retry restores the fight-start hearts and 눈치")
	check(logic.index == 0 and logic.correct == 0 and logic.wrong == 0 and logic.results.is_empty(), "retry restarts at blank 1 with a clean sheet")
	for b in logic.blanks:
		second_order.append(logic.options_for(b))
	check(first_order != second_order, "a retry reshuffles the options")
	gs.free()

	# Shuffle: a permutation, stable per seed and attempt, different per seed.
	gs = make_gs()
	var la := FightLogic.new(song, 11, gs)
	var lb := FightLogic.new(song, 11, gs)
	var lc := FightLogic.new(song, 12, gs)
	var perm_ok := true
	var same_ab := true
	var differs_c := false
	for b in la.blanks:
		var oa := la.options_for(b)
		var sorted := oa.duplicate()
		sorted.sort()
		var orig: Array = b["options"].duplicate()
		orig.sort()
		perm_ok = perm_ok and sorted == orig
		same_ab = same_ab and oa == lb.options_for(b) and oa == la.options_for(b)
		differs_c = differs_c or oa != lc.options_for(b)
	check(perm_ok, "the shuffled options are the same three options")
	check(same_ab, "same seed, same order, every call")
	check(differs_c, "another seed shuffles differently")
	var moved := false
	for b in la.blanks:
		var sheet_order: Array[String] = []
		for o in b["options"]:
			sheet_order.append(str(o))
		moved = moved or la.options_for(b) != sheet_order
	check(moved, "the options are actually shuffled, not left in sheet order")
	gs.free()

	# A custom wrong-answer cost comes from tuning.
	check(TuningScript.fight_config()["wrong_halves"] == 2, "tuning.json: a wrong answer costs 2 halves")


## A fight scene on the autoload GameState, stepped by hand.
func _make_fight(seed_number := 3, auto := "", clock: SongClock = null) -> Node3D:
	var song: Dictionary = SongData.load_file(SONG_PATH)
	var fight: Node3D = load("res://scenes/fight.tscn").instantiate()
	fight.setup(song, seed_number, auto, true, clock)
	root.add_child(fight)
	return fight


func _press_confirm(node: Node) -> void:
	var e := InputEventAction.new()
	e.action = "confirm"
	e.pressed = true
	node._unhandled_input(e)


func _test_fight_scene() -> void:
	print("Fight scene")
	var gs := _gs()
	gs.new_game()
	gs.begin_fight("eunju")
	var fight := _make_fight()
	await _frames(2)
	check(fight.state == fight.State.PLAYING and fight.clock is SilentSongClock and fight.clock.is_playing(), "starts playing on the silent clock")
	check(fight.get_node_or_null("Arena/Eunju") != null and fight.get_node_or_null("Arena/Boram") != null and fight.get_node_or_null("Arena/Banjugi") != null, "gray-box room: 은주, 보람, 반주기")
	var dev := get_nodes_in_group("dev_labels").filter(func(n): return fight.is_ancestor_of(n))
	check(dev.size() >= 5, "the usual dev labels are in the dev_labels group")
	fight.step(1.0)
	check(is_equal_approx(fight.clock.get_position(), 1.0), "the clock runs while playing")

	# The freeze at blank 1.
	check(fight.play_to_freeze(), "a freeze comes")
	check(fight.state == fight.State.FREEZE and is_equal_approx(fight.clock.get_position(), 5.0), "frozen at blank 1's time (5.0s)")
	check(not fight.clock.is_playing(), "the clock is paused at the blank")
	check(fight.options.size() == 3 and fight.options.has("노란") and fight.get_node("Arena/Attack") != null, "3 options shown, an attack object is out")
	var label: Label3D = fight.get_node("Arena/Attack/AttackId")
	check(label.text == "booger_flick", "the attack object is labelled with its attack id")
	var x0: float = fight.get_node("Arena/Attack").position.x
	var t0: float = fight.freeze_left
	fight.step(2.0)
	check(is_equal_approx(fight.freeze_left, t0 - 2.0) and fight.get_node("Arena/Attack").position.x < x0 - 1.0, "the attack creeps toward 보람 and the timer counts down")
	check(is_equal_approx(fight.clock.get_position(), 5.0), "the song stays frozen while the attack creeps")
	check(fight._timer_label.visible and fight._timer_label.text == "%.1f" % fight.freeze_left, "the timer is visible")
	check(fight._line_labels.any(func(l): return l.text.contains("[ ____ ]")), "the lyric line shows the blank on the 반주기")

	# Navigation: W/S wrap, Enter picks.
	var up := InputEventAction.new()
	up.action = "ui_up"
	up.pressed = true
	fight._unhandled_input(up)
	check(fight.selected == 2, "W / up wraps from the first option to the last")
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	fight._unhandled_input(down)
	check(fight.selected == 0, "S / down moves on")
	fight.selected = fight.options.find("노란")
	var hearts_before: int = gs.hearts_halves
	_press_confirm(fight)
	check(fight.state == fight.State.BEAT and fight.last_result["right"], "Enter picks the highlighted option; 노란 is right")
	check(fight._banner.text.contains("booger_flick_slapstick"), "a right answer shows the counter id as a placeholder beat")
	check(gs.hearts_halves == hearts_before and fight.bursts == 0, "no heart lost, no blood on a right answer")
	fight.finish_beat()
	check(fight.state == fight.State.PLAYING and fight.clock.is_playing() and fight._attack == null, "the song continues after the counter")

	# Wrong answer.
	fight.play_to_freeze()
	check(fight.logic.current()["n"] == 2 and is_equal_approx(fight.clock.get_position(), 14.0), "blank 2 freezes at 14.0s")
	var wrong_index: int = fight.options.find("냉장고")
	fight.pick(wrong_index)
	check(not fight.last_result["right"] and gs.hearts_halves == 8, "a wrong answer costs 1 heart")
	check(fight.bursts == 1 and fight.flashes == 1, "the blood burst and flash fire")
	check(fight._banner.text.contains("프라이팬"), "the correct answer is shown")
	fight.finish_beat()
	check(fight.state == fight.State.PLAYING, "then the song continues")

	# Timeout.
	fight.play_to_freeze()
	for i in 200:
		if fight.state == fight.State.FREEZE:
			fight.step(0.05)
	check(fight.last_result["timeout"] and not fight.last_result["right"] and gs.hearts_halves == 6, "the attack reaching 보람 is a timeout: wrong, -1 heart")
	check(fight.bursts == 2, "the timeout bursts too")
	fight.queue_free()
	await _frames(2)

	# A clock injected through setup: the fight only uses the interface.
	gs.new_game()
	gs.begin_fight("eunju")
	var rec := RecordingClock.new()
	fight = _make_fight(3, "", rec)
	await _frames(1)
	fight.play_to_freeze()
	check(fight.clock == rec and rec.calls.has("play") and rec.calls.has("pause") and is_equal_approx(rec.pos, 5.0), "the fight drives a replacement clock through play/pause/seek/tick")
	fight.pick_right()
	fight.finish_beat()
	check(rec.calls.has("resume") and rec.running, "and resumes it after the answer")
	fight.queue_free()
	await _frames(2)

	# A whole fight, all right: revenge.
	gs.new_game()
	gs.damage(4)
	gs.begin_fight("eunju")
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(_n): return true)
	check(fight.state == fight.State.RESULT and fight.card_kind == "revenge", "all right: the revenge card")
	check(fight._card_score.text == "점수: 100점", "the score reads 점수: 100점")
	check(gs.hearts_halves == 10 and gs.outcomes["eunju"] == "revenge" and gs.scores["eunju"] == 100, "revenge: hearts to 5, outcome and score saved")
	check(fight._card_splats.visible and fight.bursts >= 2 and fight._card_layer.visible, "the carnage card shows with a blood burst")
	_press_confirm(fight)
	check(fight.state == fight.State.END and fight._card_title.text == "END OF BUILD 4b", "after the score screen: the END OF BUILD 4b card")
	fight.queue_free()
	await _frames(2)

	# Survival.
	gs.new_game()
	gs.begin_fight("eunju")
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(n): return n != 2 and n != 9)
	check(fight.card_kind == "survival" and fight._card_score.text == "점수: 80점", "two wrong: the survival card, 점수: 80점")
	check(gs.hearts_halves == 6 and gs.outcomes["eunju"] == "survival" and not fight._card_splats.visible, "survival: no restore, no carnage")
	fight.queue_free()
	await _frames(2)

	# Game over, then retry.
	gs.new_game()
	gs.add_nunchi(2)
	gs.set_progress("sat_roam")
	gs.begin_fight("eunju")
	fight = _make_fight()
	await _frames(1)
	var counts := watch(gs, ["player_died", "state_reset"])
	fight.run_scripted(func(_n): return false)
	check(fight.state == fight.State.GAME_OVER and fight.card_kind == "gameover" and gs.hearts_halves == 0, "5 wrong answers: game over at 0 hearts")
	check(fight.logic.index == 5 and fight.lost_signals == 1, "the fight stops at the fifth wrong answer")
	check(counts["player_died"] == 0 and counts["state_reset"] == 0 and gs.progress == "sat_roam" and gs.in_fight, "no outside-fight death reset")
	var song: Dictionary = SongData.load_file(SONG_PATH)
	check(fight._card_title.text == "문태식" and fight._card_body.text == song["game_over"]["line"], "the anchor card carries the sheet's line verbatim")
	check(fight._retry_button.visible and fight._retry_button.text == "다시 부른다", "a 다시 부른다 button")
	fight.retry()
	check(fight.state == fight.State.PLAYING and fight.retries == 1, "retry plays again")
	check(gs.hearts_halves == 10 and gs.nunchi == 2, "retry restored the fight-start hearts and 눈치")
	check(fight.logic.index == 0 and is_equal_approx(fight.clock.get_position(), 0.0) and not fight._retry_button.visible, "...from phase 1, the card gone")
	for round_no in 3:
		fight.run_scripted(func(_n): return false)
		fight.retry()
	check(fight.retries == 4 and fight.state == fight.State.PLAYING, "retries are unlimited")
	fight.queue_free()
	await _frames(2)

	# Retry by Enter on the game over card.
	gs.new_game()
	gs.begin_fight("eunju")
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(_n): return false)
	_press_confirm(fight)
	check(fight.state == fight.State.PLAYING and fight.retries == 1, "Enter on the game over card retries too")
	fight.queue_free()
	await _frames(2)

	# Auto modes (stepped in real-time slices).
	for mode in [["right", "revenge", 100], ["mixed", "survival", 70]]:
		gs.new_game()
		gs.begin_fight("eunju")
		fight = _make_fight(3, mode[0])
		await _frames(1)
		var guard := 0
		while fight.state != fight.State.END and guard < 4000:
			fight.step(0.1)
			guard += 1
		check(fight.state == fight.State.END and fight.last_result["outcome"] == mode[1] and fight.last_result["score"] == mode[2], "--fight-auto %s plays through to the end card (%s, %d)" % [mode[0], mode[1], mode[2]])
		fight.queue_free()
		await _frames(2)
	gs.new_game()
	gs.begin_fight("eunju")
	fight = _make_fight(3, "wrong")
	await _frames(1)
	var g2 := 0
	while fight.state != fight.State.GAME_OVER and g2 < 4000:
		fight.step(0.1)
		g2 += 1
	check(fight.state == fight.State.GAME_OVER and fight.logic.wrong == 5, "--fight-auto wrong runs into the game over")
	fight.queue_free()
	await _frames(2)
	gs.new_game()


func _test_fight_world() -> void:
	print("Fight in the world: args, autosave, resume")
	var WorldScript = load("res://scripts/world.gd")
	var a: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--fight", "eunju", "--fight-auto", "mixed", "--hearts", "3", "--seed", "4"]))
	check(a["fight"] == "eunju" and a["fight_auto"] == "mixed" and a["hearts_halves"] == 6 and a["seed"] == 4, "--fight eunju --fight-auto mixed combine with --hearts and --seed")
	var none: Dictionary = WorldScript.parse_launch_args(PackedStringArray([]))
	check(none["fight"] == "" and none["fight_auto"] == "" and not none["capture_fight"], "no fight args by default")
	check(WorldScript.parse_launch_args(PackedStringArray(["--fight-auto", "sideways"]))["fight_auto"] == "", "a bad --fight-auto is ignored")
	check(WorldScript.parse_launch_args(PackedStringArray(["--fight"]))["fight"] == "", "--fight with no id is ignored")
	check(WorldScript.parse_launch_args(PackedStringArray(["--fight", "--new-game"]))["fight"] == "", "--fight does not eat the next flag")
	check(WorldScript.parse_launch_args(PackedStringArray(["--capture-fight"]))["capture_fight"], "--capture-fight recognised")
	check(SongData.find_for_boss("eunju") == SONG_PATH and SongData.find_for_boss("nobody") == "", "songs are found by their boss field")

	var gs := _gs()
	var world: Node = await _start_world()
	gs.set_progress("sat_roam")
	gs.damage(3)
	gs.add_nunchi(2)
	var fight: Node3D = world.start_fight("eunju", "", false, true)
	await _frames(2)
	check(fight != null and world.fight == fight and gs.in_fight and gs.current_boss == "eunju", "start_fight begins the fight")
	check(gs.fight_snapshot == {"hearts_halves": 7, "nunchi": 2}, "the snapshot is hearts and 눈치 at the start")
	check(fight.is_inside_tree() and fight.get_parent() == world, "the fight is a child of the world")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(gs.save_path))
	check(saved["state"]["in_fight"] == true and saved["state"]["fight_snapshot"]["hearts_halves"] == 7 and saved["state"]["hearts_halves"] == 7, "autosaved at the fight start")
	# Trouble mid-fight is not saved.
	fight.play_to_freeze()
	fight.pick_wrong()
	check(gs.hearts_halves == 5, "a wrong answer in the world's fight costs a heart")
	var again = JSON.parse_string(FileAccess.get_file_as_string(gs.save_path))
	check(again["state"]["hearts_halves"] == 7, "nothing is saved mid-fight: the save still holds the fight start")
	await _stop_world(world)

	# Relaunch: the save is loaded, the fight resumes at its start with the snapshot.
	gs.new_game()
	gs.damage(8)
	world = await _start_world(true)
	await _frames(2)
	check(world.fight != null and gs.in_fight and gs.current_boss == "eunju", "relaunching mid-fight resumes the fight")
	check(gs.hearts_halves == 7 and gs.nunchi == 2 and gs.progress == "sat_roam", "...with the saved hearts and 눈치 and progress")
	check(world.fight.state == world.fight.State.PLAYING and world.fight.clock.get_position() < 0.5 and world.fight.logic.index == 0, "...at the start of the song")
	check(world.player == null and world.room == null, "a resumed fight replaces the map: no player, no room")
	check(world.hud != null and world.hud.get_parent() == world, "the HUD stays up during the fight")
	# Finish it (revenge); the result is saved and a relaunch no longer enters the fight.
	world.fight.manual = true
	world.fight.run_scripted(func(_n): return true)
	check(gs.hearts_halves == 10 and gs.outcomes.get("eunju") == "revenge", "a revenge win in the world restores the hearts")
	var done = JSON.parse_string(FileAccess.get_file_as_string(gs.save_path))
	check(done["state"]["in_fight"] == false and done["state"]["outcomes"]["eunju"] == "revenge" and done["state"]["scores"]["eunju"] == 100, "the result is autosaved")
	await _stop_world(world)
	world = await _start_world(true)
	check(world.fight == null and world.room_id != "", "after the fight a relaunch loads the map again")
	await _stop_world(world)

	# --fight on a fresh game, with the fight-auto mode passed through.
	world = await _start_world()
	var f2: Node3D = world.start_fight("eunju", "right")
	check(f2.auto_mode == "right" and f2.manual == false, "start_fight passes the auto mode")
	await _stop_world(world)
	gs.new_game()
	_clean_world_saves()


# ── Build 4b: cross-outs, loaded blanks, taunts, lighting, sandbox ───────

func _fresh_fight_state(nunchi := 0, known: Array = []) -> void:
	var gs := _gs()
	gs.new_game()
	for card in known:
		gs.lose_secret(card, "eunju")
	if nunchi > 0:
		gs.add_nunchi(nunchi)
	gs.begin_fight("eunju")


func _freeze_at(fight: Node3D, n: int) -> void:
	while int(fight.logic.current()["n"]) < n:
		fight.play_to_freeze()
		fight.pick_right()
		fight.finish_beat()
	fight.play_to_freeze()


func _press_key(node: Node, keycode: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = keycode
	e.pressed = true
	node._unhandled_input(e)


func _test_build_4b() -> void:
	print("Build 4b")
	var gs := _gs()
	var song: Dictionary = SongData.load_file(SONG_PATH)
	var sheet := SongSheet.parse(FileAccess.get_file_as_string(SHEET_PATH))

	# Sandboxed saves.
	var real := GameStateScript.SAVE_PATH
	var box := GameStateScript.SANDBOX_PATH
	check(GameStateScript.resolve_save_path(PackedStringArray(["--fight", "eunju", "--fight-auto", "right"])) == box, "sandbox: --fight-auto")
	check(GameStateScript.resolve_save_path(PackedStringArray(["--capture-fight"])) == box and GameStateScript.resolve_save_path(PackedStringArray(["--capture-hud"])) == box, "sandbox: --capture-*")
	check(GameStateScript.resolve_save_path(PackedStringArray(), PackedStringArray(["-s", "res://tests/run_tests.gd"])) == box, "sandbox: the test runner (-s script run)")
	check(GameStateScript.resolve_save_path(PackedStringArray(["--sandbox"])) == box, "sandbox: --sandbox")
	check(GameStateScript.resolve_save_path(PackedStringArray(["--fight", "eunju", "--new-game"])) == real and GameStateScript.resolve_save_path(PackedStringArray()) == real, "no sandbox arg: the real save path")
	check(box.begins_with("user://sandbox/"), "the sandbox path is under user://sandbox/")

	# Launch args.
	var WorldScript = load("res://scripts/world.gd")
	var a: Dictionary = WorldScript.parse_launch_args(PackedStringArray(["--nunchi", "3", "--known", "dad_country,mom_salary,dad_drinking", "--fight-auto", "cross"]))
	check(a["nunchi"] == 3 and a["known"] == ["dad_country", "mom_salary", "dad_drinking"] and a["fight_auto"] == "cross", "--nunchi, --known and --fight-auto cross are parsed")
	var d: Dictionary = WorldScript.parse_launch_args(PackedStringArray([]))
	check(d["nunchi"] == -1 and d["known"].is_empty(), "no --nunchi / --known by default")
	check(WorldScript.parse_launch_args(PackedStringArray(["--nunchi", "x"]))["nunchi"] == -1, "a bad --nunchi is ignored")

	# Cross-outs (logic).
	_fresh_fight_state(2)
	var logic := FightLogic.new(song, 5, gs)
	var blank := logic.current()
	check(logic.can_cross_out(), "a cross-out is possible with 눈치")
	var removed := logic.cross_out()
	check(removed != "" and removed != blank["answer"] and blank["options"].has(removed), "it removes one wrong option, not the answer")
	check(gs.nunchi == 1, "it costs 1 눈치")
	check(not logic.can_cross_out() and logic.cross_out() == "" and gs.nunchi == 1, "only one cross-out per blank, and no second charge")
	check(logic.answer(removed).is_empty() and logic.index == 0, "the crossed-out option can't be picked")
	check(logic.answer(blank["answer"])["crossed"], "the result notes the cross-out")
	check(logic.can_cross_out(), "the next blank allows one again")
	var again := FightLogic.new(song, 5, gs)
	check(again.cross_out() == removed and gs.nunchi == 0, "the same seed crosses out the same option")
	check(not FightLogic.new(song, 5, gs).can_cross_out(), "no cross-out at 0 눈치")
	var never_answer := true
	for sd in 40:
		_fresh_fight_state(7)
		var lg := FightLogic.new(song, sd, gs)
		while lg.has_blank():
			never_answer = never_answer and lg.cross_out() != lg.current()["answer"]
			lg.answer(lg.current()["answer"])
	check(never_answer, "across 40 seeds the answer is never crossed out")

	# Cross-outs in the scene.
	_fresh_fight_state(3)
	var fight := _make_fight()
	await _frames(2)
	fight.play_to_freeze()
	var nunchi_before: int = gs.nunchi
	_press_key(fight, KEY_X)
	var crossed_i: int = fight.options.find(fight.logic.crossed)
	check(crossed_i != -1 and fight._option_buttons[crossed_i].disabled and fight._option_buttons[crossed_i].get_node("Strike").visible, "X strikes through one option and disables it")
	check(gs.nunchi == nunchi_before - 1 and fight._cross_hint.text == fight.HINT_USED, "it cost 1 눈치 and the hint says it is used")
	_press_key(fight, KEY_X)
	check(gs.nunchi == nunchi_before - 1, "a second X on the same blank does nothing")
	var skipped := true
	fight.selected = 0
	for i in 8:
		var down := InputEventAction.new()
		down.action = "ui_down"
		down.pressed = true
		fight._unhandled_input(down)
		skipped = skipped and fight.options[fight.selected] != fight.logic.crossed
	check(skipped, "the highlight skips the crossed-out option")
	fight.pick(crossed_i)
	check(fight.state == fight.State.FREEZE, "picking the crossed-out option does nothing")
	fight.pick_right()
	fight.finish_beat()
	fight.play_to_freeze()
	check(not fight._option_buttons[0].disabled and not fight._option_buttons[1].disabled and not fight._option_buttons[2].disabled, "the next blank starts with every option open")
	# A click on the HUD's 눈치 eyes.
	var hud: Node = load("res://scenes/hud.tscn").instantiate()
	root.add_child(hud)
	await _frames(3)
	var eyes: Control = hud.nunchi
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = eyes.get_global_rect().get_center()
	var before: int = gs.nunchi
	fight._unhandled_input(click)
	check(gs.nunchi == before - 1 and fight.logic.crossed != "", "a click on the 눈치 eyes crosses out too")
	fight.pick_right()
	fight.finish_beat()
	fight.play_to_freeze()
	click.position = Vector2(5, 700)
	fight._unhandled_input(click)
	check(fight.logic.crossed == "", "a click elsewhere does not")
	hud.queue_free()
	fight.queue_free()
	await _frames(2)

	# 0 눈치: blocked, with a hint.
	_fresh_fight_state(0)
	fight = _make_fight()
	await _frames(1)
	fight.play_to_freeze()
	_press_key(fight, KEY_X)
	check(fight.logic.crossed == "" and gs.nunchi == 0 and fight._cross_hint.text == fight.HINT_NO_NUNCHI, "at 0 눈치 a cross-out is blocked and the hint says why")
	fight.queue_free()
	await _frames(2)

	# Revenge survives cross-outs; a fight game over restores the 눈치.
	_fresh_fight_state(7)
	fight = _make_fight(3, "cross")
	await _frames(1)
	var guard := 0
	while fight.state != fight.State.END and guard < 6000:
		fight.step(0.1)
		guard += 1
	check(fight.last_result["outcome"] == "revenge" and fight.last_result["score"] == 100 and gs.hearts_halves == 10, "--fight-auto cross: a cross-out on every blank is still a revenge win")
	check(gs.nunchi == 0 and fight.logic.wrong == 0, "...and it spent 7 눈치 (one per blank until it ran out)")
	fight.queue_free()
	await _frames(2)
	_fresh_fight_state(4)
	fight = _make_fight()
	await _frames(1)
	fight.play_to_freeze()
	fight.cross_out()
	check(gs.nunchi == 3, "a cross-out before losing")
	fight.pick_wrong()
	fight.finish_beat()
	fight.run_scripted(func(_n): return false)
	check(fight.state == fight.State.GAME_OVER, "then the fight is lost")
	fight.retry()
	check(gs.nunchi == 4 and gs.hearts_halves == 10, "a fight game over restores the fight-start 눈치")
	fight.queue_free()
	await _frames(2)

	# Loaded blanks.
	var loaded_map := {}
	for item in song["loaded"]:
		loaded_map[item["card"]] = int(item["blank"])
	check(loaded_map == {"dad_country": 4, "mom_salary": 6, "dad_drinking": 9}, "the three cards map to blanks 4, 6 and 9")
	var from_sheet := {}
	for item in sheet["loaded"]:
		from_sheet[item["blank"]] = item["extra_option"]
	var matches := true
	for item in song["loaded"]:
		matches = matches and from_sheet[int(item["blank"])] == item["extra_option"]
	check(matches, "...with the sheet's extra options")
	for card in loaded_map:
		_fresh_fight_state(0, [card])
		var lg2 := FightLogic.new(song, 9, gs)
		var four_ok := true
		var others_three := true
		for b in SongData.flat_blanks(song):
			var opts := lg2.options_for(b)
			if int(b["n"]) == loaded_map[card]:
				var extra := ""
				for item in song["loaded"]:
					if item["card"] == card:
						extra = item["extra_option"]
				four_ok = four_ok and opts.size() == 4 and opts.has(extra)
			else:
				others_three = others_three and opts.size() == 3
		check(four_ok and others_three, "%s known: blank %d has 4 options with the JSON's extra option, the others 3" % [card, loaded_map[card]])
	_fresh_fight_state()
	var plain := FightLogic.new(song, 9, gs)
	check(SongData.flat_blanks(song).all(func(b): return plain.options_for(b).size() == 3), "no card known: every blank has 3 options")
	_fresh_fight_state(1, ["dad_country"])
	fight = _make_fight()
	await _frames(1)
	_freeze_at(fight, 4)
	check(fight.options.size() == 4 and fight.options.has("설탕"), "in the scene blank 4 shows 4 options with 설탕")
	fight.cross_out()
	check(fight.options.size() == 4 and fight.options.filter(func(o): return o != fight.logic.crossed).size() == 3 and fight.logic.crossed != "소금", "a cross-out on a loaded blank leaves 3 open options")
	var bursts_before: int = fight.bursts
	fight.pick_wrong()
	check(fight.last_result["loaded"] and fight.last_result["card"] == "dad_country" and fight.loaded_flourishes == 1, "a wrong answer on it lands with the flourish")
	check(fight.bursts == bursts_before + 2 and fight.shakes == 1 and fight._loaded_label.visible and fight._loaded_label.text == "LOADED: dad_country", "extra blood splat, screen shake and the LOADED label with the card id")
	fight.finish_beat()
	check(not fight._loaded_label.visible, "the label goes with the beat")
	fight.queue_free()
	await _frames(2)
	_fresh_fight_state(0, ["dad_country"])
	fight = _make_fight()
	await _frames(1)
	_freeze_at(fight, 4)
	var splats_before: int = fight.bursts
	fight.pick_right()
	check(fight.loaded_flourishes == 0 and fight.bursts == splats_before, "a right answer on a loaded blank has no flourish")
	fight.queue_free()
	await _frames(2)

	# Taunts.
	var all_cards := ["dad_country", "mom_salary", "dad_drinking"]
	var taunt_of := {}
	for item in sheet["loaded"]:
		taunt_of[item["blank"]] = item["taunt"]
	_fresh_fight_state(0, ["dad_drinking", "dad_country"])
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(n): return n != 1)
	check(fight.card_kind == "survival" and fight.aftermath.size() == 3, "survival: the line plus 2 taunts for 2 known cards")
	check(fight.aftermath[0]["text"] == "흥. 다음엔 안 불러." and sheet["survival_line"] == "흥. 다음엔 안 불러." and FileAccess.get_file_as_string(SHEET_PATH).contains("\"흥. 다음엔 안 불러.\""), "first 은주's line, as in the sheet")
	check(fight.aftermath[1]["text"] == taunt_of[4] and fight.aftermath[2]["text"] == taunt_of[9], "then the taunts in card-list order (아빠 나라, then 아빠 주량), whatever order they were learned")
	check(fight.aftermath.all(func(l): return l["speaker"] == "은주"), "all spoken by 은주")
	_press_confirm(fight)
	check(fight.state == fight.State.AFTERMATH and fight._after_panel.visible and fight._after_text.text == "흥. 다음엔 안 불러.", "Enter on the survival card opens the dialogue panel")
	_press_confirm(fight)
	check(fight._after_text.text == taunt_of[4], "Enter shows the next taunt")
	_press_confirm(fight)
	check(fight._after_text.text == taunt_of[9], "...and the next")
	var left := InputEventMouseButton.new()
	left.button_index = MOUSE_BUTTON_LEFT
	left.pressed = true
	fight._unhandled_input(left)
	check(fight.state == fight.State.END and fight._card_title.text == "END OF BUILD 4b" and not fight._after_panel.visible, "a click advances; then END OF BUILD 4b")
	fight.queue_free()
	await _frames(2)
	_fresh_fight_state(0, all_cards)
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(_n): return true)
	check(fight.card_kind == "revenge" and fight.aftermath.is_empty(), "revenge: no taunts")
	_press_confirm(fight)
	check(fight.state == fight.State.END, "revenge goes straight to the end card")
	fight.queue_free()
	await _frames(2)
	_fresh_fight_state()
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(n): return n != 2)
	check(fight.card_kind == "survival" and fight.aftermath.size() == 1 and fight.aftermath[0]["card"] == "", "survival with no known cards: only 은주's line, no taunts")
	fight.queue_free()
	await _frames(2)
	_fresh_fight_state(0, all_cards)
	fight = _make_fight()
	await _frames(1)
	fight.run_scripted(func(_n): return false)
	check(fight.state == fight.State.GAME_OVER and fight.aftermath.is_empty(), "a lost fight has no taunts")
	fight.queue_free()
	await _frames(2)

	# Speakers and text from the sheet.
	var intro: Dictionary = song["lines"][0]
	var outro: Dictionary = song["lines"][-1]
	check(intro["speaker"] == "은주" and intro["text"] == "자, 다 조용히 해! 내 노래야!", "intro: 은주, as in the sheet")
	check(outro["speaker"] == "보람" and outro["text"] == "잘 먹겠습니다." and sheet["lyrics"][-1]["text"] == outro["text"] and sheet["lyrics"][0]["text"] == intro["text"], "outro: 보람, the text as in the sheet")
	check(sheet["lyrics"][-1]["speaker"] == "은주", "the sheet itself still says 은주 for the outro (the override lives in build_song.gd)")
	check(FileAccess.get_file_as_string("res://tools/build_song.gd").contains("OUTRO_SPEAKER"), "the builder applies the outro override")
	check(song["outcomes"]["survival"]["line"] == sheet["survival_line"], "the song file carries the sheet's survival line")
	check(song["loaded"].all(func(item): return item["taunt"] != "" and not item["taunt"].begins_with("\"")), "every loaded entry has its taunt, quote marks stripped")
	check(SongData.validate(song).is_empty(), "the rebuilt song validates")

	# Lighting.
	check(song["lighting"] == {"1": "normal", "2": "normal", "3": "flicker", "4": "frantic"}, "lighting map: phases 1-2 normal, 3 flicker, 4 frantic")
	var lit := []
	for b in SongData.flat_blanks(song):
		lit.append(b.get("light", ""))
	check(lit == ["", "", "", "", "", "", "", "blackout", "", ""], "only blank 8 has a light override: blackout")
	check(TuningScript.fight_config()["lighting_effects"] == false, "tuning.json: fight lighting effects are off by default")

	# Switch off (the default): the same song data, but the lights never change.
	_fresh_fight_state()
	fight = _make_fight()
	await _frames(1)
	check(not fight.lighting_effects, "the fight reads the switch: off")
	var off_ok := true
	for n in range(1, 11):
		fight.play_to_freeze()
		for i in 40:
			fight.step(0.05)
			off_ok = off_ok and fight.lighting == "normal" and is_equal_approx(fight._sun.light_energy, fight.SUN_ENERGY) \
					and is_equal_approx(fight._env.ambient_light_energy, fight.AMBIENT_ENERGY) and fight._light_overlay.color.a == 0.0
		fight.pick_right()
		fight.finish_beat()
	check(off_ok, "effects off: no flicker, blackout (blank 8) or red phase in the whole fight")
	check(fight._light_override == "" and fight.state != fight.State.FREEZE, "effects off: the fight still ran through every blank")
	fight.queue_free()
	await _frames(2)

	# Switch on: the effects play.
	_fresh_fight_state()
	fight = _make_fight()
	fight.lighting_effects = true
	await _frames(1)
	check(fight.lighting == "normal" and is_equal_approx(fight._sun.light_energy, fight.SUN_ENERGY), "the intro is normal light")
	var modes := {}
	for n in range(1, 11):
		fight.play_to_freeze()
		modes[n] = fight.lighting
		if n == 8:
			check(fight._sun.light_energy == 0.0 and fight._env.ambient_light_energy == 0.0 and fight._light_overlay.color.a > 0.5, "blank 8: the lights go off on the reveal")
			fight.step(2.0)
			check(fight.lighting == "blackout" and fight._sun.light_energy == 0.0, "...and stay off while the attack creeps")
			fight.pick_right()
			fight.step(0.8)
			check(fight.lighting == "blackout" and fight._sun.light_energy == 0.0, "...through the counter")
			fight.finish_beat()
			check(fight.lighting == "flicker" and fight._light_override == "", "...then the phase lighting resumes")
		else:
			fight.pick_right()
			fight.finish_beat()
	check([modes[1], modes[2], modes[3], modes[4], modes[5], modes[6], modes[7], modes[9], modes[10]] == ["normal", "normal", "normal", "normal", "normal", "normal", "flicker", "frantic", "frantic"], "phase lighting at each blank: normal, normal, flicker (7), frantic (9, 10)")
	check(modes[8] == "blackout", "blank 8 reads blackout")
	var seen_energies := {}
	for i in 60:
		fight.step(0.05)
		seen_energies[snappedf(fight._sun.light_energy, 0.01)] = true
	check(fight._sun.light_color.r > 0.9 and fight._sun.light_color.g < 0.4 and seen_energies.size() >= 2 and not seen_energies.keys().any(func(e): return e > 0.5), "frantic is a dim red that flickers")
	fight.queue_free()
	await _frames(2)
	gs.new_game()

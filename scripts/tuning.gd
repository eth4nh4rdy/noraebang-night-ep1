# Reads movement tunables from data/config/tuning.json (GameState reads the rest).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
extends RefCounted

const PATH := "res://data/config/tuning.json"
const DEFAULT_LANE_COUNT := 3
const DEFAULT_LANE_SPACING := 1.5


## {"lane_count": int >= 1, "lane_spacing": float > 0}
static func lane_config() -> Dictionary:
	var config := {"lane_count": DEFAULT_LANE_COUNT, "lane_spacing": DEFAULT_LANE_SPACING}
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH)) if FileAccess.file_exists(PATH) else null
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Tuning: could not read %s, using lane defaults" % PATH)
		return config
	var count = data.get("lane_count")
	if (typeof(count) == TYPE_FLOAT or typeof(count) == TYPE_INT) and int(count) >= 1:
		config["lane_count"] = int(count)
	else:
		push_error("Tuning: lane_count missing or invalid, using %d" % DEFAULT_LANE_COUNT)
	var spacing = data.get("lane_spacing")
	if (typeof(spacing) == TYPE_FLOAT or typeof(spacing) == TYPE_INT) and float(spacing) > 0.0:
		config["lane_spacing"] = float(spacing)
	else:
		push_error("Tuning: lane_spacing missing or invalid, using %s" % DEFAULT_LANE_SPACING)
	return config


const DEFAULT_SONG_FIRST_LINE := 2.0
const DEFAULT_SONG_LINE_GAP := 3.0
const DEFAULT_WRONG_HALVES := 2


## Fight tunables: {"first_line_time": float (s), "line_gap": float (s, placeholder
## spacing between lyric lines), "wrong_halves": int (hearts a wrong answer costs),
## "lighting_effects": bool (the bridge flicker, blank 8's blackout and the red frantic phase)}.
## tools/build_song.gd bakes the two song values into the song JSON's line times.
static func fight_config() -> Dictionary:
	var config := {"first_line_time": DEFAULT_SONG_FIRST_LINE, "line_gap": DEFAULT_SONG_LINE_GAP,
			"wrong_halves": DEFAULT_WRONG_HALVES, "lighting_effects": false}
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH)) if FileAccess.file_exists(PATH) else null
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Tuning: could not read %s, using fight defaults" % PATH)
		return config
	for pair in [["song_first_line_time", "first_line_time", 0.0], ["song_line_gap", "line_gap", 0.1]]:
		var v = data.get(pair[0])
		if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and float(v) >= pair[2]:
			config[pair[1]] = float(v)
		else:
			push_error("Tuning: %s missing or invalid, using %s" % [pair[0], config[pair[1]]])
	var w = data.get("fight_wrong_halves")
	if (typeof(w) == TYPE_FLOAT or typeof(w) == TYPE_INT) and int(w) >= 1 and float(w) == floorf(float(w)):
		config["wrong_halves"] = int(w)
	else:
		push_error("Tuning: fight_wrong_halves missing or invalid, using %d" % DEFAULT_WRONG_HALVES)
	if typeof(data.get("fight_lighting_effects")) == TYPE_BOOL:
		config["lighting_effects"] = data["fight_lighting_effects"]
	else:
		push_error("Tuning: fight_lighting_effects missing or invalid, using false")
	return config

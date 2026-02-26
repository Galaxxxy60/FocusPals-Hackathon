extends CanvasLayer
## Microphone selection panel — uses _input() directly for 100% reliable click capture.
## VU meter powered by Godot's native AudioStreamMicrophone — zero Python dependency.

signal mic_selected(mic_index: int)
signal panel_closed()

var is_open := false
var _progress := 0.0
var _mics: Array = []
var _selected_index: int = -1
var _hovered: int = -1
var _canvas: Control
var _vu_level := 0.0

# Audio capture for VU meter
var _mic_player: AudioStreamPlayer
var _mic_effect: AudioEffectCapture
var _mic_bus_idx: int = -1

const PANEL_WIDTH := 310.0
const ITEM_HEIGHT := 36.0
const PADDING := 12.0
const MARGIN_RIGHT := 10.0
const VU_WIDTH := 14.0
const VU_MARGIN := 28.0  # Space reserved on the left for VU meter

func _ready() -> void:
	layer = 101
	visible = false
	_canvas = Control.new()
	_canvas.name = "MicCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.connect("draw", _draw_panel)
	add_child(_canvas)
	_setup_mic_capture()

func _setup_mic_capture() -> void:
	# Create a dedicated audio bus for mic capture
	var bus_count := AudioServer.bus_count
	AudioServer.add_bus(bus_count)
	AudioServer.set_bus_name(bus_count, "MicCapture")
	# Mute the bus — prevents mic audio from playing through speakers
	# AudioEffectCapture still receives audio data before mute is applied
	AudioServer.set_bus_mute(bus_count, true)
	_mic_bus_idx = bus_count
	
	# Add AudioEffectCapture to read raw audio samples
	_mic_effect = AudioEffectCapture.new()
	AudioServer.add_bus_effect(_mic_bus_idx, _mic_effect)
	
	# Create player with AudioStreamMicrophone
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = "MicCapture"
	_mic_player.volume_db = 0.0
	add_child(_mic_player)

func show_mics(mics: Array, selected: int) -> void:
	_mics = mics
	_selected_index = selected
	_hovered = -1
	if _mics.is_empty():
		return
	is_open = true
	visible = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)
	_progress = 0.0
	_vu_level = 0.0
	var tw := create_tween()
	tw.tween_property(self, "_progress", 1.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# Start mic capture for VU meter
	if _mic_player and not _mic_player.playing:
		_match_input_device()
		_mic_player.play()

func close() -> void:
	if not is_open:
		return
	is_open = false
	# Stop mic capture
	if _mic_player and _mic_player.playing:
		_mic_player.stop()
	var tw := create_tween()
	tw.tween_property(self, "_progress", 0.0, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		visible = false
		panel_closed.emit()
	)

# Panel centered on the radial arc center (vp.x right edge, vp.y * 0.7)
func _panel_rect() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	var arc_center_y := vp.y * 0.7
	var h := PADDING * 2 + ITEM_HEIGHT * _mics.size() + 30
	var x := vp.x - (PANEL_WIDTH + MARGIN_RIGHT) * _progress
	var y := arc_center_y - h * 0.5
	return Rect2(x, y, PANEL_WIDTH, h)

func _item_rect(index: int) -> Rect2:
	var pr := _panel_rect()
	var y := pr.position.y + 30 + PADDING + index * ITEM_HEIGHT
	# Shift right to make room for VU meter on the left
	return Rect2(pr.position.x + PADDING + VU_MARGIN, y, PANEL_WIDTH - PADDING * 2 - VU_MARGIN, ITEM_HEIGHT - 4)

func _process(delta: float) -> void:
	if not visible:
		return
	if is_open:
		_read_vu_level()
	_update_hover()
	_canvas.queue_redraw()

func _match_input_device() -> void:
	## Match our selected mic to a Godot input device by name
	var godot_devices := AudioServer.get_input_device_list()
	var selected_mic_name := ""
	for mic in _mics:
		if int(mic.get("index", -1)) == _selected_index:
			selected_mic_name = str(mic.get("name", ""))
			break
	
	var best_match := "Default"
	for gd_dev in godot_devices:
		if gd_dev == "Default":
			continue
		if selected_mic_name != "" and (selected_mic_name.to_lower() in gd_dev.to_lower() or gd_dev.to_lower() in selected_mic_name.to_lower()):
			best_match = gd_dev
			break
	
	# Fallback: first non-virtual physical device
	if best_match == "Default":
		for gd_dev in godot_devices:
			if gd_dev == "Default":
				continue
			if "CABLE" in gd_dev or "Steam" in gd_dev or "WO Mic" in gd_dev:
				continue
			best_match = gd_dev
			break
	
	AudioServer.input_device = best_match

func _read_vu_level() -> void:
	if _mic_effect == null:
		return
	var frames := _mic_effect.get_frames_available()
	if frames <= 0:
		_vu_level = lerp(_vu_level, 0.0, 0.1)
		return
	# Read all available frames
	var buf := _mic_effect.get_buffer(mini(frames, 1024))
	var peak := 0.0
	for i in buf.size():
		var sample := absf(buf[i].x)
		if sample > peak:
			peak = sample
	
	# Fast attack, slow decay
	if peak > _vu_level:
		_vu_level = lerp(_vu_level, peak, 0.5)
	else:
		_vu_level = lerp(_vu_level, peak, 0.15)

func _update_hover() -> void:
	var mouse := _canvas.get_local_mouse_position()
	_hovered = -1
	if _progress < 0.5:
		return
	for i in _mics.size():
		if _item_rect(i).has_point(mouse):
			_hovered = i
			break
	# Auto-close if mouse moves far from the panel
	if is_open and _progress >= 0.9:
		var pr := _panel_rect()
		if mouse.x < pr.position.x - 80 or mouse.y < pr.position.y - 80 or mouse.y > pr.position.y + pr.size.y + 80:
			close()

# Direct _input() — catches ALL clicks, no gui_input / MOUSE_FILTER issues
func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_viewport().set_input_as_handled()
		if _hovered >= 0:
			var mic: Dictionary = _mics[_hovered]
			var idx: int = int(mic.get("index", 0))
			_selected_index = idx
			mic_selected.emit(idx)
			var t := get_tree().create_timer(0.3)
			t.timeout.connect(close)
		else:
			var pr := _panel_rect()
			var mouse := _canvas.get_local_mouse_position()
			if not pr.has_point(mouse):
				close()

func _draw_panel() -> void:
	if _progress < 0.01:
		return

	var alpha := _progress
	var pr := _panel_rect()

	# Panel background
	_canvas.draw_rect(pr, Color(0.06, 0.06, 0.12, 0.95 * alpha), true)
	_canvas.draw_rect(pr, Color(0.3, 0.5, 0.9, 0.4 * alpha), false, 1.5)

	# Title
	var font := ThemeDB.fallback_font
	_canvas.draw_string(font, Vector2(pr.position.x + PADDING, pr.position.y + 22),
		"🎤  Microphone", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 15,
		Color(0.7, 0.85, 1.0, alpha))

	# ── Vertical Segment VU Meter (LEFT side) ──
	var num_segments := 12
	var vu_x_pos := pr.position.x + PADDING + 2
	var vu_y_start := pr.position.y + 34.0
	var vu_y_end := pr.position.y + pr.size.y - PADDING
	var vu_h_total := maxf(vu_y_end - vu_y_start, 20.0)
	var segment_gap := 2.0
	var segment_h := (vu_h_total - (num_segments - 1) * segment_gap) / num_segments

	# Background
	_canvas.draw_rect(Rect2(vu_x_pos - 3, vu_y_start - 3, VU_WIDTH + 6, vu_h_total + 6),
		Color(0.04, 0.04, 0.08, 0.9 * alpha), true)
	_canvas.draw_rect(Rect2(vu_x_pos - 3, vu_y_start - 3, VU_WIDTH + 6, vu_h_total + 6),
		Color(0.2, 0.3, 0.5, 0.3 * alpha), false, 1.0)

	for s in range(num_segments):
		var segment_index := num_segments - 1 - s  # top = highest index
		var sy := vu_y_start + s * (segment_h + segment_gap)
		var threshold := float(segment_index) / float(num_segments)
		var is_lit := _vu_level > threshold

		# Color: green → yellow → red
		var lit_color := Color(0.1, 0.9, 0.2, alpha)
		if segment_index >= num_segments - 2:
			lit_color = Color(0.95, 0.15, 0.1, alpha)
		elif segment_index >= num_segments - 4:
			lit_color = Color(0.95, 0.8, 0.1, alpha)

		var c := lit_color if is_lit else Color(lit_color.r * 0.15, lit_color.g * 0.15, lit_color.b * 0.15, 0.4 * alpha)
		_canvas.draw_rect(Rect2(vu_x_pos, sy, VU_WIDTH, segment_h), c, true)

	# Separator
	var sep_y := pr.position.y + 28
	_canvas.draw_line(Vector2(pr.position.x + PADDING, sep_y),
		Vector2(pr.position.x + PANEL_WIDTH - PADDING, sep_y),
		Color(0.3, 0.5, 0.8, 0.3 * alpha), 1.0)

	# Mic items
	for i in _mics.size():
		_draw_mic_item(i, alpha)

func _draw_mic_item(index: int, alpha: float) -> void:
	var rect := _item_rect(index)
	var mic: Dictionary = _mics[index]
	var mic_index: int = int(mic.get("index", 0))
	var mic_name: String = str(mic.get("name", "?"))
	var is_selected := mic_index == _selected_index
	var is_hovered := index == _hovered
	var font := ThemeDB.fallback_font

	if is_selected:
		_canvas.draw_rect(rect, Color(0.15, 0.45, 0.25, 0.7 * alpha), true)
		_canvas.draw_rect(Rect2(rect.position.x, rect.position.y, 3, rect.size.y), Color(0.3, 1.0, 0.5, alpha), true)
		_canvas.draw_rect(rect, Color(0.3, 1.0, 0.5, 0.5 * alpha), false, 1.0)
	elif is_hovered:
		_canvas.draw_rect(rect, Color(0.2, 0.35, 0.6, 0.4 * alpha), true)
		_canvas.draw_rect(rect, Color(0.4, 0.7, 1.0, 0.4 * alpha), false, 1.0)

	var ix := rect.position.x + 12
	var iy := rect.position.y + rect.size.y * 0.5
	if is_selected:
		_canvas.draw_circle(Vector2(ix, iy), 7, Color(0.3, 1.0, 0.5, alpha))
		_canvas.draw_string(font, Vector2(ix - 5, iy + 5), "✓", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0, 0, 0, alpha))
	else:
		_canvas.draw_circle(Vector2(ix, iy), 6, Color(0.4, 0.5, 0.6, 0.3 * alpha))
		_canvas.draw_circle(Vector2(ix, iy), 4, Color(0.06, 0.06, 0.12, 0.9 * alpha))

	if mic_name.length() > 25:
		mic_name = mic_name.substr(0, 23) + "…"
	var text_color := Color(1, 1, 1, alpha) if is_selected else Color(0.7, 0.75, 0.8, alpha)
	_canvas.draw_string(font, Vector2(ix + 16, rect.position.y + rect.size.y * 0.65),
		mic_name, HORIZONTAL_ALIGNMENT_LEFT, int(rect.size.x - 55), 12, text_color)

	if is_selected:
		var bs := font.get_string_size("ACTIF", HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
		var bx := rect.position.x + rect.size.x - bs.x - 10
		var by := iy - bs.y * 0.3
		_canvas.draw_rect(Rect2(bx - 4, by - 2, bs.x + 8, bs.y + 4), Color(0.2, 0.8, 0.4, 0.3 * alpha), true)
		_canvas.draw_string(font, Vector2(bx, by + bs.y - 1), "ACTIF", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.4, 1.0, 0.6, alpha))

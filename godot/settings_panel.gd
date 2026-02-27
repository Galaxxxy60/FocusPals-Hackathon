extends CanvasLayer
## Scrollable settings panel — mic selection + API key + future sections.
## Content scrolls via mouse wheel. Max visible height = 70% viewport.
## Uses _input() for 100% reliable click/scroll capture.

signal mic_selected(mic_index: int)
signal panel_closed()
signal api_key_submitted(key: String)
signal language_changed(lang: String)
signal volume_changed(volume: float)

var is_open := false
var _progress := 0.0
var _mics: Array = []
var _selected_index: int = -1
var _hovered_mic: int = -1
var _vu_level := 0.0

# API Key
var _api_key_masked := ""
var _api_key_editing := false
var _api_key_buffer := ""
var _api_key_cursor_blink := 0.0
var _hovered_api_btn: int = -1
var _api_key_has_key := false
var _api_key_valid: int = -1  # -1 = unknown/checking, 0 = invalid, 1 = valid
var _api_key_checking := false

# Language dropdown
var _language := "fr"
var _lang_dropdown_open := false
var _hovered_lang_item: int = -1  # index in LANGUAGES array

# Volume slider
var _tama_volume := 1.0  # 0.0 to 1.0
var _volume_dragging := false
var _hovered_volume := false

# API Usage stats
var _api_usage := {}

# Scroll
var _scroll_offset := 0.0       # px scrolled (0 = top)
var _scroll_target := 0.0       # smooth scroll target
var _max_scroll := 0.0          # computed each frame
var _scrollbar_hovered := false

# Audio capture for VU meter
var _mic_player: AudioStreamPlayer
var _mic_effect: AudioEffectCapture
var _mic_bus_idx: int = -1

# Canvas
var _canvas: Control

const PANEL_WIDTH := 340.0
const ITEM_HEIGHT := 36.0
const PADDING := 14.0
const MARGIN_RIGHT := 10.0
const VU_WIDTH := 14.0
const VU_MARGIN := 28.0
const SECTION_HEADER_H := 32.0
const API_KEY_SECTION_H := 80.0
const LANG_SECTION_H := 44.0
const LANG_ITEM_H := 28.0
const LANG_DROPDOWN_W := 200.0
const LANGUAGES := [
	{"code": "fr", "label": "Francais"},
	{"code": "en", "label": "English"},
]
const VOLUME_SECTION_H := 50.0
const VOLUME_SLIDER_H := 8.0
const VOLUME_THUMB_R := 8.0
const API_USAGE_SECTION_H := 130.0
const TITLE_H := 36.0
const SCROLL_SPEED := 40.0
const SCROLLBAR_WIDTH := 4.0
const MAX_HEIGHT_RATIO := 0.70   # Panel never taller than 70% viewport

func _ready() -> void:
	layer = 101
	visible = false
	_canvas = Control.new()
	_canvas.name = "SettingsCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.connect("draw", _draw_panel)
	add_child(_canvas)
	_setup_mic_capture()

func _setup_mic_capture() -> void:
	var bus_count := AudioServer.bus_count
	AudioServer.add_bus(bus_count)
	AudioServer.set_bus_name(bus_count, "MicCapture")
	AudioServer.set_bus_volume_db(bus_count, -80.0)
	_mic_bus_idx = bus_count
	_mic_effect = AudioEffectCapture.new()
	AudioServer.add_bus_effect(_mic_bus_idx, _mic_effect)
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = "MicCapture"
	_mic_player.volume_db = 0.0
	add_child(_mic_player)

# ─── Public API ────────────────────────────────────────────

func show_settings(mics: Array, selected: int, has_api_key: bool, key_valid: bool = false, lang: String = "fr", volume: float = 1.0, api_usage: Dictionary = {}) -> void:
	_mics = mics
	_selected_index = selected
	_hovered_mic = -1
	_hovered_api_btn = -1
	_api_key_editing = false
	_api_key_buffer = ""
	_api_key_has_key = has_api_key
	_api_key_masked = "••••••••••••••••" if has_api_key else ""
	_api_key_checking = false
	if has_api_key:
		_api_key_valid = 1 if key_valid else 0
	else:
		_api_key_valid = -1
	_scroll_offset = 0.0
	_scroll_target = 0.0
	_language = lang
	_lang_dropdown_open = false
	_hovered_lang_item = -1
	_tama_volume = clampf(volume, 0.0, 1.0)
	_volume_dragging = false
	_hovered_volume = false
	_api_usage = api_usage

	is_open = true
	visible = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)
	_progress = 0.0
	_vu_level = 0.0
	var tw := create_tween()
	tw.tween_property(self, "_progress", 1.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _mic_player and not _mic_player.playing:
		_match_input_device()
		_mic_player.play()

func close() -> void:
	if not is_open:
		return
	is_open = false
	_api_key_editing = false
	if _mic_player and _mic_player.playing:
		_mic_player.stop()
	var tw := create_tween()
	tw.tween_property(self, "_progress", 0.0, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		visible = false
		panel_closed.emit()
	)

# ─── Geometry ──────────────────────────────────────────────

func _content_height() -> float:
	## Total height of ALL content (may exceed visible area)
	var mic_items_h := ITEM_HEIGHT * _mics.size()
	return SECTION_HEADER_H + mic_items_h + 12 + SECTION_HEADER_H + API_KEY_SECTION_H + 12 + SECTION_HEADER_H + LANG_SECTION_H + 12 + SECTION_HEADER_H + VOLUME_SECTION_H + 12 + SECTION_HEADER_H + API_USAGE_SECTION_H + PADDING

func _visible_height() -> float:
	## Panel height capped to MAX_HEIGHT_RATIO of viewport
	var vp := get_viewport().get_visible_rect().size
	var max_h := vp.y * MAX_HEIGHT_RATIO
	return minf(TITLE_H + _content_height(), max_h)

func _panel_rect() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	var arc_center_y := vp.y * 0.7
	var h := _visible_height()
	var x := vp.x - (PANEL_WIDTH + MARGIN_RIGHT) * _progress
	var y := arc_center_y - h * 0.5
	# Clamp so we don't go off-screen
	y = clampf(y, 10.0, vp.y - h - 10.0)
	return Rect2(x, y, PANEL_WIDTH, h)

## All "content Y" methods return positions RELATIVE to panel top,
## then _content_y_to_screen() applies the scroll offset.

func _content_y_to_screen(content_y: float) -> float:
	## Convert a content-space Y to screen-space Y (with scroll applied)
	var pr := _panel_rect()
	return pr.position.y + TITLE_H + content_y - _scroll_offset

func _mic_section_content_y() -> float:
	return 0.0  # First section starts at top of content area

func _mic_item_rect(index: int) -> Rect2:
	var pr := _panel_rect()
	var cy := _mic_section_content_y() + SECTION_HEADER_H + index * ITEM_HEIGHT
	var sy := _content_y_to_screen(cy)
	return Rect2(pr.position.x + PADDING + VU_MARGIN, sy, PANEL_WIDTH - PADDING * 2 - VU_MARGIN, ITEM_HEIGHT - 4)

func _api_section_content_y() -> float:
	return _mic_section_content_y() + SECTION_HEADER_H + ITEM_HEIGHT * _mics.size() + 12

func _api_input_rect() -> Rect2:
	var pr := _panel_rect()
	var cy := _api_section_content_y() + SECTION_HEADER_H + 4
	var sy := _content_y_to_screen(cy)
	return Rect2(pr.position.x + PADDING, sy, PANEL_WIDTH - PADDING * 2 - 60, 28)

func _api_btn_rect() -> Rect2:
	var pr := _panel_rect()
	var cy := _api_section_content_y() + SECTION_HEADER_H + 4
	var sy := _content_y_to_screen(cy)
	return Rect2(pr.position.x + PANEL_WIDTH - PADDING - 50, sy, 50, 28)

func _lang_section_content_y() -> float:
	return _api_section_content_y() + SECTION_HEADER_H + API_KEY_SECTION_H + 12

func _lang_selector_rect() -> Rect2:
	## The main dropdown button showing current language
	var pr = _panel_rect()
	var cy = _lang_section_content_y() + SECTION_HEADER_H + 4
	var sy = _content_y_to_screen(cy)
	return Rect2(pr.position.x + PADDING, sy, LANG_DROPDOWN_W, LANG_ITEM_H)

func _lang_dropdown_item_rect(index: int) -> Rect2:
	## Rect for an individual item in the open dropdown list (opens UPWARD)
	var sel_r = _lang_selector_rect()
	var items_count = LANGUAGES.size()
	return Rect2(sel_r.position.x, sel_r.position.y - (items_count - index) * LANG_ITEM_H, LANG_DROPDOWN_W, LANG_ITEM_H)

func _volume_section_content_y() -> float:
	return _lang_section_content_y() + SECTION_HEADER_H + LANG_SECTION_H + 12

func _api_usage_section_content_y() -> float:
	return _volume_section_content_y() + SECTION_HEADER_H + VOLUME_SECTION_H + 12

func _volume_slider_rect() -> Rect2:
	## The slider track rect (full width)
	var pr := _panel_rect()
	var cy := _volume_section_content_y() + SECTION_HEADER_H + 14
	var sy := _content_y_to_screen(cy)
	return Rect2(pr.position.x + PADDING + 30, sy, PANEL_WIDTH - PADDING * 2 - 70, VOLUME_SLIDER_H)

func _volume_thumb_center() -> Vector2:
	var sr := _volume_slider_rect()
	var tx := sr.position.x + _tama_volume * sr.size.x
	var ty := sr.position.y + sr.size.y * 0.5
	return Vector2(tx, ty)

func _content_area_rect() -> Rect2:
	## The visible scrollable area (below the title)
	var pr := _panel_rect()
	return Rect2(pr.position.x, pr.position.y + TITLE_H, pr.size.x, pr.size.y - TITLE_H)

# ─── Process ───────────────────────────────────────────────

func _process(delta: float) -> void:
	if not visible:
		return
	if is_open:
		_read_vu_level()
		_api_key_cursor_blink += delta * 3.0

	# Smooth scroll interpolation
	_scroll_offset = lerp(_scroll_offset, _scroll_target, delta * 15.0)

	# Compute max scroll
	var content_h := _content_height()
	var visible_h := _visible_height() - TITLE_H
	_max_scroll = maxf(content_h - visible_h, 0.0)
	_scroll_target = clampf(_scroll_target, 0.0, _max_scroll)

	_update_hover()
	_canvas.queue_redraw()

func _match_input_device() -> void:
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
	var buf := _mic_effect.get_buffer(mini(frames, 1024))
	var peak := 0.0
	for i in buf.size():
		var sample := absf(buf[i].x)
		if sample > peak:
			peak = sample
	peak = clampf(peak * 2.5, 0.0, 1.0)
	if peak > _vu_level:
		_vu_level = lerp(_vu_level, peak, 0.5)
	else:
		_vu_level = lerp(_vu_level, peak, 0.15)

func _is_in_content_area(screen_y: float) -> bool:
	var ca := _content_area_rect()
	return screen_y >= ca.position.y and screen_y <= ca.position.y + ca.size.y

func _update_hover() -> void:
	var mouse := _canvas.get_local_mouse_position()
	_hovered_mic = -1
	_hovered_api_btn = -1
	_hovered_volume = false
	if _progress < 0.5:
		return

	# Only hover items that are visible (inside content area)
	for i in _mics.size():
		var r := _mic_item_rect(i)
		if r.has_point(mouse) and _is_in_content_area(r.position.y) and _is_in_content_area(r.position.y + r.size.y):
			_hovered_mic = i
			break

	var btn_r := _api_btn_rect()
	if btn_r.has_point(mouse) and _is_in_content_area(btn_r.position.y):
		_hovered_api_btn = 0

	# Volume slider hover detection
	var vol_sr := _volume_slider_rect()
	var vol_thumb := _volume_thumb_center()
	var vol_hover_rect := Rect2(vol_sr.position.x - 10, vol_sr.position.y - 12, vol_sr.size.x + 20, vol_sr.size.y + 24)
	if vol_hover_rect.has_point(mouse) and _is_in_content_area(vol_sr.position.y):
		_hovered_volume = true

	# Auto-close if mouse moves far away
	if is_open and _progress >= 0.9 and not _volume_dragging:
		var pr := _panel_rect()
		if mouse.x < pr.position.x - 80 or mouse.y < pr.position.y - 80 or mouse.y > pr.position.y + pr.size.y + 80:
			close()

	# Language dropdown hover
	_hovered_lang_item = -1
	if _lang_dropdown_open:
		for li in LANGUAGES.size():
			var lr = _lang_dropdown_item_rect(li)
			if lr.has_point(mouse):
				_hovered_lang_item = li
				break
	else:
		var sel_r = _lang_selector_rect()
		if sel_r.has_point(mouse) and _is_in_content_area(sel_r.position.y):
			_hovered_lang_item = -2  # hovering the selector button itself

# ─── Input ─────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not is_open:
		return

	# Mouse wheel → scroll
	if event is InputEventMouseButton and event.pressed:
		var pr := _panel_rect()
		var mouse := _canvas.get_local_mouse_position()
		if pr.has_point(mouse):
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_target = clampf(_scroll_target + SCROLL_SPEED, 0.0, _max_scroll)
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll_target = clampf(_scroll_target - SCROLL_SPEED, 0.0, _max_scroll)
				get_viewport().set_input_as_handled()
				return

	# Volume slider drag
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var vol_mouse := _canvas.get_local_mouse_position()
		if event.pressed:
			var vol_sr := _volume_slider_rect()
			var vol_hover := Rect2(vol_sr.position.x - 10, vol_sr.position.y - 14, vol_sr.size.x + 20, vol_sr.size.y + 28)
			if vol_hover.has_point(vol_mouse) and _is_in_content_area(vol_sr.position.y):
				_volume_dragging = true
				_tama_volume = clampf((vol_mouse.x - vol_sr.position.x) / vol_sr.size.x, 0.0, 1.0)
				volume_changed.emit(_tama_volume)
				get_viewport().set_input_as_handled()
				return
		else:
			if _volume_dragging:
				_volume_dragging = false
				get_viewport().set_input_as_handled()
				return

	if event is InputEventMouseMotion and _volume_dragging:
		var drag_mouse := _canvas.get_local_mouse_position()
		var vol_sr := _volume_slider_rect()
		_tama_volume = clampf((drag_mouse.x - vol_sr.position.x) / vol_sr.size.x, 0.0, 1.0)
		volume_changed.emit(_tama_volume)
		get_viewport().set_input_as_handled()
		return

	# Text input for API key editing
	if _api_key_editing and event is InputEventKey and event.pressed:
		get_viewport().set_input_as_handled()
		if event.keycode == KEY_ESCAPE:
			_api_key_editing = false
			_api_key_buffer = ""
			return
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			_submit_api_key()
			return
		elif event.keycode == KEY_V and event.ctrl_pressed:
			# Ctrl+V — paste from clipboard
			var clipboard := DisplayServer.clipboard_get().strip_edges()
			if clipboard.length() > 0:
				_api_key_buffer += clipboard
			return
		elif event.keycode == KEY_A and event.ctrl_pressed:
			# Ctrl+A — select all (clear and ready for paste)
			_api_key_buffer = ""
			return
		elif event.keycode == KEY_BACKSPACE:
			if _api_key_buffer.length() > 0:
				_api_key_buffer = _api_key_buffer.substr(0, _api_key_buffer.length() - 1)
			return
		elif event.unicode > 0:
			var ch := char(event.unicode)
			if ch.strip_edges() != "" or ch == " ":
				_api_key_buffer += ch
			return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_viewport().set_input_as_handled()

		# Mic item click
		if _hovered_mic >= 0:
			var mic: Dictionary = _mics[_hovered_mic]
			var idx: int = int(mic.get("index", 0))
			_selected_index = idx
			mic_selected.emit(idx)
			_match_input_device()
			return

		# API button click
		if _hovered_api_btn == 0:
			if _api_key_editing:
				_submit_api_key()
			else:
				_api_key_editing = true
				_api_key_buffer = ""
				_api_key_cursor_blink = 0.0
			return

		# API input field click
		var input_r := _api_input_rect()
		if input_r.has_point(_canvas.get_local_mouse_position()) and _is_in_content_area(input_r.position.y):
			if not _api_key_editing:
				_api_key_editing = true
				_api_key_buffer = ""
				_api_key_cursor_blink = 0.0
			return

		# Language dropdown clicks
		if _lang_dropdown_open:
			if _hovered_lang_item >= 0:
				var picked = LANGUAGES[_hovered_lang_item]
				if picked["code"] != _language:
					_language = picked["code"]
					language_changed.emit(_language)
				_lang_dropdown_open = false
				return
			else:
				_lang_dropdown_open = false
				return
		else:
			var sel_r = _lang_selector_rect()
			if sel_r.has_point(_canvas.get_local_mouse_position()) and _is_in_content_area(sel_r.position.y):
				_lang_dropdown_open = true
				return

		# Click outside panel → close
		var pr := _panel_rect()
		var mouse := _canvas.get_local_mouse_position()
		if not pr.has_point(mouse):
			close()

func _submit_api_key() -> void:
	var key := _api_key_buffer.strip_edges()
	if key.length() > 0:
		api_key_submitted.emit(key)
		_api_key_has_key = true
		_api_key_masked = "••••••••••••••••"
		_api_key_valid = -1  # Unknown until Python validates
		_api_key_checking = true
	_api_key_editing = false
	_api_key_buffer = ""

func update_key_valid(valid: bool) -> void:
	## Called by main.gd when Python sends API_KEY_UPDATED
	_api_key_valid = 1 if valid else 0
	_api_key_checking = false
	_api_key_has_key = true

# ─── Drawing ───────────────────────────────────────────────

func _draw_panel() -> void:
	if _progress < 0.01:
		return

	var alpha := _progress
	var pr := _panel_rect()
	var ca := _content_area_rect()
	var font := ThemeDB.fallback_font

	# ── Panel background ──
	_canvas.draw_rect(pr, Color(0.05, 0.05, 0.1, 0.96 * alpha), true)
	_canvas.draw_rect(pr, Color(0.3, 0.5, 0.9, 0.5 * alpha), false, 1.5)

	# ── Title (fixed, never scrolls) ──
	_canvas.draw_string(font, Vector2(pr.position.x + PADDING, pr.position.y + 24),
		"⚙️  Réglages", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 16,
		Color(0.85, 0.9, 1.0, alpha))
	var title_sep_y := pr.position.y + TITLE_H - 4
	_canvas.draw_line(Vector2(pr.position.x + PADDING, title_sep_y),
		Vector2(pr.position.x + PANEL_WIDTH - PADDING, title_sep_y),
		Color(0.3, 0.5, 0.8, 0.3 * alpha), 1.0)

	# ═══════════════════════════════════════════════════════
	#  SCROLLABLE CONTENT (clipped to content area)
	# ═══════════════════════════════════════════════════════

	# ── SECTION: Microphone ──
	var mic_cy := _mic_section_content_y()
	var mic_sy := _content_y_to_screen(mic_cy)
	if _is_in_content_area(mic_sy + 20):
		_canvas.draw_string(font, Vector2(pr.position.x + PADDING, mic_sy + 20),
			"🎤  Microphone", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 13,
			Color(0.6, 0.8, 1.0, alpha))
	var mic_sep_sy := _content_y_to_screen(mic_cy + SECTION_HEADER_H - 6)
	if _is_in_content_area(mic_sep_sy):
		_canvas.draw_line(Vector2(pr.position.x + PADDING + 4, mic_sep_sy),
			Vector2(pr.position.x + PANEL_WIDTH - PADDING - 4, mic_sep_sy),
			Color(0.25, 0.4, 0.7, 0.2 * alpha), 1.0)

	# VU Meter
	_draw_vu_meter(alpha, ca)

	# Mic items
	for i in _mics.size():
		_draw_mic_item(i, alpha, ca)

	# ── SECTION: API Key ──
	var api_cy := _api_section_content_y()
	var api_sy := _content_y_to_screen(api_cy)

	# Separator above
	if _is_in_content_area(api_sy - 2):
		_canvas.draw_line(Vector2(pr.position.x + PADDING, api_sy - 2),
			Vector2(pr.position.x + PANEL_WIDTH - PADDING, api_sy - 2),
			Color(0.3, 0.5, 0.8, 0.2 * alpha), 1.0)

	if _is_in_content_area(api_sy + 20):
		_canvas.draw_string(font, Vector2(pr.position.x + PADDING, api_sy + 20),
			"🔑  Clé API Gemini", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 13,
			Color(0.6, 0.8, 1.0, alpha))

	# Input field
	var input_r := _api_input_rect()
	if _is_in_content_area(input_r.position.y) and _is_in_content_area(input_r.position.y + input_r.size.y):
		var input_bg := Color(0.08, 0.08, 0.15, 0.9 * alpha)
		var input_border := Color(0.3, 0.5, 0.8, 0.4 * alpha)
		if _api_key_editing:
			input_bg = Color(0.1, 0.1, 0.18, 0.95 * alpha)
			input_border = Color(0.4, 0.7, 1.0, 0.7 * alpha)
		_canvas.draw_rect(input_r, input_bg, true)
		_canvas.draw_rect(input_r, input_border, false, 1.0)

		# Input text
		var display_text := ""
		if _api_key_editing:
			display_text = "•".repeat(_api_key_buffer.length())
			if int(_api_key_cursor_blink) % 2 == 0:
				display_text += "│"
		elif _api_key_has_key:
			display_text = _api_key_masked
		else:
			display_text = "Aucune clé configurée"

		var text_color := Color(0.7, 0.75, 0.8, alpha)
		if _api_key_editing:
			text_color = Color(0.9, 0.95, 1.0, alpha)
		elif not _api_key_has_key:
			text_color = Color(0.5, 0.4, 0.4, alpha)

		_canvas.draw_string(font, Vector2(input_r.position.x + 8, input_r.position.y + input_r.size.y * 0.7),
			display_text, HORIZONTAL_ALIGNMENT_LEFT, int(input_r.size.x - 12), 11, text_color)

	# Button (Edit / Save)
	var btn_r := _api_btn_rect()
	if _is_in_content_area(btn_r.position.y) and _is_in_content_area(btn_r.position.y + btn_r.size.y):
		var btn_label := "✏️ Edit" if not _api_key_editing else "💾 OK"
		var btn_bg := Color(0.15, 0.25, 0.4, 0.7 * alpha)
		var btn_border := Color(0.4, 0.6, 0.9, 0.4 * alpha)
		if _hovered_api_btn == 0:
			btn_bg = Color(0.2, 0.35, 0.55, 0.8 * alpha)
			btn_border = Color(0.5, 0.75, 1.0, 0.6 * alpha)
		if _api_key_editing:
			btn_bg = Color(0.15, 0.4, 0.25, 0.8 * alpha)
			btn_border = Color(0.3, 0.9, 0.5, 0.5 * alpha)
		_canvas.draw_rect(btn_r, btn_bg, true)
		_canvas.draw_rect(btn_r, btn_border, false, 1.0)
		_canvas.draw_string(font, Vector2(btn_r.position.x + 6, btn_r.position.y + btn_r.size.y * 0.7),
			btn_label, HORIZONTAL_ALIGNMENT_LEFT, int(btn_r.size.x - 8), 10, Color(1, 1, 1, alpha))

	# Status indicator with validation icon
	var status_sy := input_r.position.y + input_r.size.y + 12
	if _is_in_content_area(status_sy):
		var status_text := ""
		var status_color := Color(0.5, 0.5, 0.5, alpha)
		var dot_color := Color(0.5, 0.5, 0.5, alpha)
		var dot_x := pr.position.x + PADDING + 6
		var dot_y := status_sy - 3
		
		if _api_key_editing:
			status_text = "   Tapez votre clé puis Entrée ou 💾"
			status_color = Color(0.5, 0.7, 1.0, 0.7 * alpha)
			_canvas.draw_circle(Vector2(dot_x, dot_y), 5, Color(0.3, 0.5, 0.8, 0.5 * alpha))
			_canvas.draw_string(font, Vector2(dot_x - 3, dot_y + 4), "✏", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.7, 0.85, 1.0, alpha))
		elif _api_key_checking:
			status_text = "   Vérification en cours..."
			status_color = Color(0.6, 0.7, 0.9, 0.7 * alpha)
			# Animated spinner dot
			var spin_alpha := 0.5 + 0.5 * sin(_api_key_cursor_blink * 2.0)
			_canvas.draw_circle(Vector2(dot_x, dot_y), 5, Color(0.4, 0.6, 1.0, spin_alpha * alpha))
			_canvas.draw_circle(Vector2(dot_x, dot_y), 3, Color(0.2, 0.3, 0.5, 0.8 * alpha))
		elif _api_key_valid == 1:
			status_text = "   Clé valide"
			status_color = Color(0.3, 0.9, 0.4, 0.8 * alpha)
			# Green dot with checkmark
			_canvas.draw_circle(Vector2(dot_x, dot_y), 6, Color(0.15, 0.5, 0.2, 0.8 * alpha))
			_canvas.draw_circle(Vector2(dot_x, dot_y), 5, Color(0.2, 0.85, 0.35, 0.9 * alpha))
			_canvas.draw_string(font, Vector2(dot_x - 4, dot_y + 4), "✓", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, alpha))
		elif _api_key_valid == 0:
			status_text = "   Clé invalide"
			status_color = Color(0.95, 0.3, 0.25, 0.8 * alpha)
			# Red dot with cross
			_canvas.draw_circle(Vector2(dot_x, dot_y), 6, Color(0.5, 0.1, 0.1, 0.8 * alpha))
			_canvas.draw_circle(Vector2(dot_x, dot_y), 5, Color(0.9, 0.2, 0.15, 0.9 * alpha))
			_canvas.draw_string(font, Vector2(dot_x - 3, dot_y + 4), "✗", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, alpha))
		else:
			status_text = "   Clé requise pour démarrer"
			status_color = Color(0.9, 0.5, 0.3, 0.7 * alpha)
			_canvas.draw_circle(Vector2(dot_x, dot_y), 5, Color(0.6, 0.35, 0.15, 0.6 * alpha))
			_canvas.draw_string(font, Vector2(dot_x - 3, dot_y + 4), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 0.8, 0.4, alpha))
		
		_canvas.draw_string(font, Vector2(pr.position.x + PADDING, status_sy),
			status_text, HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 10, status_color)

	# ── SECTION: Language ──
	var lang_cy := _lang_section_content_y()
	var lang_sy := _content_y_to_screen(lang_cy)

	# Separator above
	if _is_in_content_area(lang_sy - 2):
		_canvas.draw_line(Vector2(pr.position.x + PADDING, lang_sy - 2),
			Vector2(pr.position.x + PANEL_WIDTH - PADDING, lang_sy - 2),
			Color(0.3, 0.5, 0.8, 0.2 * alpha), 1.0)

	if _is_in_content_area(lang_sy + 20):
		_canvas.draw_string(font, Vector2(pr.position.x + PADDING, lang_sy + 20),
			"🌐  Langue / Language", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 13,
			Color(0.6, 0.8, 1.0, alpha))

	# Language dropdown selector
	var sel_r = _lang_selector_rect()
	if _is_in_content_area(sel_r.position.y):
		# Find current language label
		var cur_label = _language.to_upper()
		for ld in LANGUAGES:
			if ld["code"] == _language:
				cur_label = ld["label"]
				break

		# Selector button
		var sel_bg = Color(0.08, 0.08, 0.15, 0.9 * alpha)
		var sel_border = Color(0.3, 0.5, 0.8, 0.4 * alpha)
		if _hovered_lang_item == -2 or _lang_dropdown_open:
			sel_bg = Color(0.12, 0.12, 0.2, 0.95 * alpha)
			sel_border = Color(0.4, 0.7, 1.0, 0.6 * alpha)
		_canvas.draw_rect(sel_r, sel_bg, true)
		_canvas.draw_rect(sel_r, sel_border, false, 1.0)
		_canvas.draw_string(font, Vector2(sel_r.position.x + 10, sel_r.position.y + sel_r.size.y * 0.7),
			cur_label, HORIZONTAL_ALIGNMENT_LEFT, int(sel_r.size.x - 30), 11, Color(0.9, 0.95, 1.0, alpha))
		# Arrow indicator
		var arrow_text = "v" if not _lang_dropdown_open else "^"
		_canvas.draw_string(font, Vector2(sel_r.position.x + sel_r.size.x - 18, sel_r.position.y + sel_r.size.y * 0.7),
			arrow_text, HORIZONTAL_ALIGNMENT_LEFT, 20, 11, Color(0.5, 0.6, 0.8, alpha))

		# Dropdown items (only when open)
		if _lang_dropdown_open:
			for di in LANGUAGES.size():
				var dir = _lang_dropdown_item_rect(di)
				var item_bg = Color(0.06, 0.06, 0.12, 0.95 * alpha)
				var item_text_col = Color(0.7, 0.75, 0.8, alpha)
				if LANGUAGES[di]["code"] == _language:
					item_bg = Color(0.12, 0.35, 0.2, 0.9 * alpha)
					item_text_col = Color(0.4, 1.0, 0.6, alpha)
				elif _hovered_lang_item == di:
					item_bg = Color(0.15, 0.25, 0.4, 0.9 * alpha)
					item_text_col = Color(0.9, 0.95, 1.0, alpha)
				_canvas.draw_rect(dir, item_bg, true)
				_canvas.draw_rect(dir, Color(0.2, 0.35, 0.6, 0.3 * alpha), false, 1.0)
				var item_label = LANGUAGES[di]["label"]
				if LANGUAGES[di]["code"] == _language:
					item_label = item_label + "  >"
				_canvas.draw_string(font, Vector2(dir.position.x + 10, dir.position.y + dir.size.y * 0.7),
					item_label, HORIZONTAL_ALIGNMENT_LEFT, int(dir.size.x - 16), 11, item_text_col)

	# ── SECTION: Volume ──
	var vol_cy := _volume_section_content_y()
	var vol_sy := _content_y_to_screen(vol_cy)

	# Separator above
	if _is_in_content_area(vol_sy - 2):
		_canvas.draw_line(Vector2(pr.position.x + PADDING, vol_sy - 2),
			Vector2(pr.position.x + PANEL_WIDTH - PADDING, vol_sy - 2),
			Color(0.3, 0.5, 0.8, 0.2 * alpha), 1.0)

	if _is_in_content_area(vol_sy + 20):
		_canvas.draw_string(font, Vector2(pr.position.x + PADDING, vol_sy + 20),
			"\U0001f50a  Volume Tama", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 13,
			Color(0.6, 0.8, 1.0, alpha))

	# Volume slider
	var vol_sr := _volume_slider_rect()
	if _is_in_content_area(vol_sr.position.y):
		# Speaker icon (muted vs on)
		var icon_x := pr.position.x + PADDING + 4
		var icon_y := vol_sr.position.y + vol_sr.size.y * 0.5 + 4
		var icon_text := "\U0001f507" if _tama_volume < 0.01 else "\U0001f509" if _tama_volume < 0.5 else "\U0001f50a"
		_canvas.draw_string(font, Vector2(icon_x, icon_y),
			icon_text, HORIZONTAL_ALIGNMENT_LEFT, 20, 12, Color(0.6, 0.75, 0.9, alpha))

		# Track background
		var track_color := Color(0.12, 0.12, 0.2, 0.8 * alpha)
		_canvas.draw_rect(Rect2(vol_sr.position.x, vol_sr.position.y, vol_sr.size.x, vol_sr.size.y), track_color, true)
		_canvas.draw_rect(Rect2(vol_sr.position.x, vol_sr.position.y, vol_sr.size.x, vol_sr.size.y),
			Color(0.25, 0.4, 0.6, 0.3 * alpha), false, 1.0)

		# Filled portion
		var fill_w := _tama_volume * vol_sr.size.x
		if fill_w > 1.0:
			var fill_color := Color(0.3, 0.6, 1.0, 0.8 * alpha)
			if _hovered_volume or _volume_dragging:
				fill_color = Color(0.4, 0.7, 1.0, 0.9 * alpha)
			_canvas.draw_rect(Rect2(vol_sr.position.x, vol_sr.position.y, fill_w, vol_sr.size.y), fill_color, true)

		# Thumb
		var thumb_c := _volume_thumb_center()
		var thumb_r := VOLUME_THUMB_R
		var thumb_color := Color(0.5, 0.75, 1.0, alpha)
		var thumb_border := Color(0.3, 0.5, 0.8, 0.6 * alpha)
		if _volume_dragging:
			thumb_color = Color(0.6, 0.85, 1.0, alpha)
			thumb_border = Color(0.4, 0.7, 1.0, 0.8 * alpha)
			thumb_r = VOLUME_THUMB_R + 2
		elif _hovered_volume:
			thumb_color = Color(0.55, 0.8, 1.0, alpha)
			thumb_r = VOLUME_THUMB_R + 1
		_canvas.draw_circle(thumb_c, thumb_r + 1, thumb_border)
		_canvas.draw_circle(thumb_c, thumb_r, thumb_color)

		# Percentage text
		var pct_text := str(int(_tama_volume * 100)) + "%"
		var pct_x := vol_sr.position.x + vol_sr.size.x + 10
		var pct_y := vol_sr.position.y + vol_sr.size.y * 0.5 + 5
		_canvas.draw_string(font, Vector2(pct_x, pct_y),
			pct_text, HORIZONTAL_ALIGNMENT_LEFT, 40, 11,
			Color(0.7, 0.8, 0.9, alpha))

	# ── SECTION: API Usage ──
	var usage_cy := _api_usage_section_content_y()
	var usage_sy := _content_y_to_screen(usage_cy)

	# Separator above
	if _is_in_content_area(usage_sy - 2):
		_canvas.draw_line(Vector2(pr.position.x + PADDING, usage_sy - 2),
			Vector2(pr.position.x + PANEL_WIDTH - PADDING, usage_sy - 2),
			Color(0.3, 0.5, 0.8, 0.2 * alpha), 1.0)

	if _is_in_content_area(usage_sy + 20):
		_canvas.draw_string(font, Vector2(pr.position.x + PADDING, usage_sy + 20),
			"\U0001f4ca  API Usage", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 13,
			Color(0.6, 0.8, 1.0, alpha))

	# Stats rows — 2 columns
	var row_h := 18.0
	var col1_x := pr.position.x + PADDING + 6
	var col2_x := pr.position.x + PADDING + PANEL_WIDTH * 0.5
	var val_offset := 120.0  # distance from label start to value
	var val2_offset := 100.0
	var label_color := Color(0.55, 0.65, 0.75, alpha)
	var value_color := Color(0.85, 0.92, 1.0, alpha)
	var icon_size := 10

	var row0_cy := usage_cy + SECTION_HEADER_H + 8
	# Row 0: Connections + Connection time
	var r0_sy := _content_y_to_screen(row0_cy)
	if _is_in_content_area(r0_sy):
		_canvas.draw_string(font, Vector2(col1_x, r0_sy + row_h * 0.7),
			"\U0001f50c Connexions", HORIZONTAL_ALIGNMENT_LEFT, int(val_offset), icon_size, label_color)
		var conn_val := str(int(_api_usage.get("connections", 0)))
		_canvas.draw_string(font, Vector2(col1_x + val_offset, r0_sy + row_h * 0.7),
			conn_val, HORIZONTAL_ALIGNMENT_LEFT, 60, icon_size, value_color)
		_canvas.draw_string(font, Vector2(col2_x, r0_sy + row_h * 0.7),
			"\u23f1 Temps co.", HORIZONTAL_ALIGNMENT_LEFT, int(val2_offset), icon_size, label_color)
		var secs := int(_api_usage.get("connect_secs", 0))
		var time_str := _format_duration(secs)
		_canvas.draw_string(font, Vector2(col2_x + val2_offset, r0_sy + row_h * 0.7),
			time_str, HORIZONTAL_ALIGNMENT_LEFT, 80, icon_size, value_color)

	# Row 1: Screen pulses + Function calls
	var r1_sy := _content_y_to_screen(row0_cy + row_h + 4)
	if _is_in_content_area(r1_sy):
		_canvas.draw_string(font, Vector2(col1_x, r1_sy + row_h * 0.7),
			"\U0001f4f8 Scans", HORIZONTAL_ALIGNMENT_LEFT, int(val_offset), icon_size, label_color)
		var pulses_val := _format_number(int(_api_usage.get("screen_pulses", 0)))
		_canvas.draw_string(font, Vector2(col1_x + val_offset, r1_sy + row_h * 0.7),
			pulses_val, HORIZONTAL_ALIGNMENT_LEFT, 60, icon_size, value_color)
		_canvas.draw_string(font, Vector2(col2_x, r1_sy + row_h * 0.7),
			"\u2699 Fn calls", HORIZONTAL_ALIGNMENT_LEFT, int(val2_offset), icon_size, label_color)
		var fc_val := _format_number(int(_api_usage.get("function_calls", 0)))
		_canvas.draw_string(font, Vector2(col2_x + val2_offset, r1_sy + row_h * 0.7),
			fc_val, HORIZONTAL_ALIGNMENT_LEFT, 60, icon_size, value_color)

	# Row 2: Audio sent + Audio received
	var r2_sy := _content_y_to_screen(row0_cy + (row_h + 4) * 2)
	if _is_in_content_area(r2_sy):
		_canvas.draw_string(font, Vector2(col1_x, r2_sy + row_h * 0.7),
			"\U0001f3a4 Audio \u2191", HORIZONTAL_ALIGNMENT_LEFT, int(val_offset), icon_size, label_color)
		var audio_sent := _format_number(int(_api_usage.get("audio_sent", 0)))
		_canvas.draw_string(font, Vector2(col1_x + val_offset, r2_sy + row_h * 0.7),
			audio_sent, HORIZONTAL_ALIGNMENT_LEFT, 60, icon_size, value_color)
		_canvas.draw_string(font, Vector2(col2_x, r2_sy + row_h * 0.7),
			"\U0001f50a Audio \u2193", HORIZONTAL_ALIGNMENT_LEFT, int(val2_offset), icon_size, label_color)
		var audio_recv := _format_number(int(_api_usage.get("audio_recv", 0)))
		_canvas.draw_string(font, Vector2(col2_x + val2_offset, r2_sy + row_h * 0.7),
			audio_recv, HORIZONTAL_ALIGNMENT_LEFT, 60, icon_size, value_color)

	# Subtle "since app start" note
	var note_sy := _content_y_to_screen(row0_cy + (row_h + 4) * 3 + 4)
	if _is_in_content_area(note_sy):
		_canvas.draw_string(font, Vector2(col1_x, note_sy + 8),
			"Depuis le lancement", HORIZONTAL_ALIGNMENT_LEFT, int(PANEL_WIDTH - PADDING * 2), 9,
			Color(0.4, 0.45, 0.55, 0.6 * alpha))

	# ═══════════════════════════════════════════════════════
	#  SCROLLBAR (only if content overflows)
	# ═══════════════════════════════════════════════════════
	if _max_scroll > 0.01:
		_draw_scrollbar(alpha, ca)


func _draw_scrollbar(alpha: float, ca: Rect2) -> void:
	var bar_x := ca.position.x + ca.size.x - SCROLLBAR_WIDTH - 3
	var track_h := ca.size.y - 8
	var track_y := ca.position.y + 4

	# Track background
	_canvas.draw_rect(Rect2(bar_x, track_y, SCROLLBAR_WIDTH, track_h),
		Color(0.15, 0.15, 0.25, 0.3 * alpha), true)

	# Thumb
	var content_h := _content_height()
	var visible_h := _visible_height() - TITLE_H
	var thumb_ratio := clampf(visible_h / content_h, 0.1, 1.0)
	var thumb_h := maxf(track_h * thumb_ratio, 20.0)
	var scroll_ratio := _scroll_offset / maxf(_max_scroll, 0.01)
	var thumb_y := track_y + scroll_ratio * (track_h - thumb_h)

	var thumb_color := Color(0.4, 0.6, 1.0, 0.5 * alpha)
	_canvas.draw_rect(Rect2(bar_x, thumb_y, SCROLLBAR_WIDTH, thumb_h),
		thumb_color, true)


func _draw_vu_meter(alpha: float, ca: Rect2) -> void:
	var pr := _panel_rect()
	if _mics.is_empty():
		return

	var num_segments := 12
	var vu_x_pos := pr.position.x + PADDING + 2
	var vu_cy_start := _mic_section_content_y() + SECTION_HEADER_H
	var vu_cy_end := vu_cy_start + ITEM_HEIGHT * _mics.size()
	var vu_sy_start := _content_y_to_screen(vu_cy_start)
	var vu_sy_end := _content_y_to_screen(vu_cy_end)

	# Skip if completely outside content area
	if vu_sy_end < ca.position.y or vu_sy_start > ca.position.y + ca.size.y:
		return

	var vu_h_total := maxf(vu_sy_end - vu_sy_start, 20.0)
	var segment_gap := 2.0
	var segment_h := (vu_h_total - (num_segments - 1) * segment_gap) / num_segments

	# Background
	_canvas.draw_rect(Rect2(vu_x_pos - 3, vu_sy_start - 3, VU_WIDTH + 6, vu_h_total + 6),
		Color(0.04, 0.04, 0.08, 0.9 * alpha), true)
	_canvas.draw_rect(Rect2(vu_x_pos - 3, vu_sy_start - 3, VU_WIDTH + 6, vu_h_total + 6),
		Color(0.2, 0.3, 0.5, 0.3 * alpha), false, 1.0)

	for s in range(num_segments):
		var segment_index := num_segments - 1 - s
		var sy := vu_sy_start + s * (segment_h + segment_gap)
		if not _is_in_content_area(sy):
			continue
		var threshold := float(segment_index) / float(num_segments)
		var is_lit := _vu_level > threshold

		var lit_color := Color(0.1, 0.9, 0.2, alpha)
		if segment_index >= num_segments - 2:
			lit_color = Color(0.95, 0.15, 0.1, alpha)
		elif segment_index >= num_segments - 4:
			lit_color = Color(0.95, 0.8, 0.1, alpha)

		var c := lit_color if is_lit else Color(lit_color.r * 0.15, lit_color.g * 0.15, lit_color.b * 0.15, 0.4 * alpha)
		_canvas.draw_rect(Rect2(vu_x_pos, sy, VU_WIDTH, segment_h), c, true)


func _draw_mic_item(index: int, alpha: float, ca: Rect2) -> void:
	var rect := _mic_item_rect(index)

	# Skip if outside visible content area
	if rect.position.y + rect.size.y < ca.position.y or rect.position.y > ca.position.y + ca.size.y:
		return

	var mic: Dictionary = _mics[index]
	var mic_index: int = int(mic.get("index", 0))
	var mic_name: String = str(mic.get("name", "?"))
	var is_selected := mic_index == _selected_index
	var is_hovered := index == _hovered_mic
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

# ─── Formatting Helpers ────────────────────────────────────

func _format_duration(total_secs: int) -> String:
	if total_secs < 60:
		return str(total_secs) + "s"
	var mins := total_secs / 60
	var secs := total_secs % 60
	if mins < 60:
		return str(mins) + "m " + str(secs) + "s"
	var hours := mins / 60
	mins = mins % 60
	return str(hours) + "h " + str(mins) + "m"

func _format_number(n: int) -> String:
	if n < 1000:
		return str(n)
	elif n < 10000:
		return str(n / 1000) + "." + str((n % 1000) / 100) + "k"
	else:
		return str(n / 1000) + "k"

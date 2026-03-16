extends CanvasLayer
## Hidden debug tweaks panel — opened with F2.
## Communicates with Python via WebSocket GET_TWEAKS / SET_TWEAK.
## Minimal and quick: a few sliders for key A.S.C. variables.

signal tweak_changed(key: String, value: float)

var is_open := false
var _bg: ColorRect = null      # Full-screen click catcher (blocks OS passthrough on layered windows)
var _panel: PanelContainer = null
var _sliders := {}   # key → {slider: HSlider, label: Label}
var _toggles := {}   # key → {checkbox: CheckBox}

# Each tweak: {key, label, min, max, step, default, suffix}
const TWEAKS := [
	{"key": "suspicion_gain_mult", "label": "⚡ S Gain Speed", "min": 0.1, "max": 5.0, "step": 0.1, "default": 1.0, "suffix": "x"},
	{"key": "suspicion_decay_mult", "label": "💧 S Decay Speed", "min": 0.1, "max": 5.0, "step": 0.1, "default": 1.0, "suffix": "x"},
	{"key": "confidence", "label": "🛡️ Confidence (C)", "min": 0.1, "max": 1.0, "step": 0.05, "default": 1.0, "suffix": ""},
	{"key": "mood_decay_secs", "label": "🎭 Mood Decay", "min": 5.0, "max": 60.0, "step": 5.0, "default": 20.0, "suffix": "s"},
	{"key": "pulse_delay_mult", "label": "📡 Pulse Delay", "min": 0.5, "max": 3.0, "step": 0.25, "default": 1.0, "suffix": "x"},
	{"key": "voice_pitch", "label": "🎀 Voice Pitch", "min": 0.8, "max": 1.4, "step": 0.05, "default": 1.0, "suffix": "x"},
]

# Stability toggles — these require reconnection to take effect
const STABILITY_TOGGLES := [
	{"key": "affective_dialog", "label": "🎭 Affective Dialog", "default": true},
	{"key": "proactive_audio", "label": "🗣️ Proactive Audio", "default": true},
	{"key": "thinking", "label": "🧠 Thinking Budget", "default": true},
]

func _ready() -> void:
	layer = 150
	visible = false

func toggle() -> void:
	if is_open:
		_close()
	else:
		_open()

func _open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)
	_build_ui()
	# Tell Python to disable Win32 click-through (WS_EX_TRANSPARENT)
	var main_node = get_parent()
	if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		main_node.ws.send_text(JSON.stringify({"command": "SHOW_TWEAKS"}))
		# Also request current values
		main_node.ws.send_text(JSON.stringify({"command": "GET_TWEAKS"}))

func _close() -> void:
	if not is_open:
		return
	is_open = false
	if _bg:
		_bg.queue_free()
		_bg = null
	if _panel:
		_panel.queue_free()
		_panel = null
	_sliders.clear()
	_toggles.clear()
	visible = false
	# Tell Python to re-enable Win32 click-through
	var main_node = get_parent()
	if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		main_node.ws.send_text(JSON.stringify({"command": "HIDE_TWEAKS"}))
	# Restore Godot-side passthrough if no other panel is open
	if main_node:
		main_node._safe_restore_passthrough()

func update_values(values: Dictionary) -> void:
	## Called when Python sends TWEAKS_DATA — update slider positions and toggle states.
	for key in values:
		if _sliders.has(key):
			var info: Dictionary = _sliders[key]
			var slider: HSlider = info["slider"]
			var label: Label = info["label"]
			var tweak: Dictionary = info["tweak"]
			slider.set_value_no_signal(values[key])
			label.text = _format_val(values[key], tweak)
		if _toggles.has(key):
			var checkbox: CheckBox = _toggles[key]
			checkbox.set_pressed_no_signal(values[key] >= 0.5)
			checkbox.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5) if values[key] >= 0.5 else Color(1.0, 0.4, 0.4))

func _build_ui() -> void:
	if _bg:
		_bg.queue_free()
	if _panel:
		_panel.queue_free()
	_sliders.clear()

	var vp := get_viewport().get_visible_rect().size

	# Full-screen click catcher — blocks OS-level click passthrough on layered windows
	# (same pattern as the radial menu: Color(0,0,0,0.01) = nearly invisible)
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.01)
	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_bg.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			_close()  # Click outside panel → close
	)
	add_child(_bg)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.906, 0.933, 0.965, 0.97)  # #e7eef6
	style.border_color = Color(0.502, 0.682, 0.890)     # #80aee3
	style.set_border_width_all(2)
	style.set_corner_radius_all(3)
	style.shadow_color = Color(0.553, 0.737, 0.918, 0.3)  # #8dbcea
	style.shadow_size = 4
	_panel.add_theme_stylebox_override("panel", style)

	var panel_w := 300.0
	_panel.custom_minimum_size = Vector2(panel_w, 0)
	_panel.position = Vector2(20, vp.y * 0.15)
	add_child(_panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 0)
	_panel.add_child(root_vbox)

	# --- Title Bar ---
	var title_panel := PanelContainer.new()
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = Color(0.227, 0.353, 0.541)  # RETRO_TEXT
	t_style.border_color = Color(0.345, 0.537, 0.769)  # RETRO_DARK
	t_style.set_border_width_all(1)
	t_style.content_margin_left = 6
	t_style.content_margin_right = 6
	t_style.content_margin_top = 4
	t_style.content_margin_bottom = 4
	title_panel.add_theme_stylebox_override("panel", t_style)
	root_vbox.add_child(title_panel)

	var title_row := HBoxContainer.new()
	title_panel.add_child(title_row)

	var title := Label.new()
	title.text = "🔧 Debug Tweaks"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var hint := Label.new()
	hint.text = "F2"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.863, 0.910, 0.957, 0.8))  # Light blue
	title_row.add_child(hint)

	# --- Content Area ---
	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_top", 12)
	content_margin.add_theme_constant_override("margin_bottom", 12)
	content_margin.add_theme_constant_override("margin_left", 16)
	content_margin.add_theme_constant_override("margin_right", 16)
	root_vbox.add_child(content_margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	content_margin.add_child(vbox)

	# Separator
	var sep := HSeparator.new()
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.502, 0.682, 0.890, 0.4)  # #80aee3
	sep_style.set_content_margin_all(0)
	sep_style.content_margin_top = 3
	sep_style.content_margin_bottom = 3
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# Sliders
	for tweak in TWEAKS:
		_add_slider(vbox, tweak)

	# ── Stability Toggles ──
	var sep2 := HSeparator.new()
	var sep2_style := StyleBoxFlat.new()
	sep2_style.bg_color = Color(0.502, 0.682, 0.890, 0.4)  # #80aee3
	sep2_style.set_content_margin_all(0)
	sep2_style.content_margin_top = 6
	sep2_style.content_margin_bottom = 3
	sep2.add_theme_stylebox_override("separator", sep2_style)
	vbox.add_child(sep2)

	var toggle_title := Label.new()
	toggle_title.text = "⚠️ Stability (reconnects)"
	toggle_title.add_theme_font_size_override("font_size", 10)
	toggle_title.add_theme_color_override("font_color", Color(0.345, 0.537, 0.769))  # RETRO_DARK
	vbox.add_child(toggle_title)

	for toggle in STABILITY_TOGGLES:
		_add_toggle(vbox, toggle)

	# Reset button
	var reset_btn := Button.new()
	reset_btn.text = "↩️ Reset All"
	reset_btn.custom_minimum_size.y = 28
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.863, 0.910, 0.957)  # #dce8f4
	btn_style.border_color = Color(0.878, 0.533, 0.533, 0.4)  # Light red border
	btn_style.set_border_width_all(1)
	btn_style.set_corner_radius_all(3)
	btn_style.set_content_margin_all(4)
	var btn_hover := StyleBoxFlat.new()
	btn_hover.bg_color = Color(0.878, 0.533, 0.533, 0.2)
	btn_hover.border_color = Color(0.878, 0.533, 0.533, 0.8)
	btn_hover.set_border_width_all(2)
	btn_hover.set_corner_radius_all(3)
	btn_hover.set_content_margin_all(4)
	reset_btn.add_theme_stylebox_override("normal", btn_style)
	reset_btn.add_theme_stylebox_override("hover", btn_hover)
	reset_btn.add_theme_stylebox_override("pressed", btn_hover)
	reset_btn.add_theme_font_size_override("font_size", 11)
	reset_btn.add_theme_color_override("font_color", Color(0.878, 0.533, 0.533))
	reset_btn.pressed.connect(_on_reset_all)
	vbox.add_child(reset_btn)

func _add_slider(parent: VBoxContainer, tweak: Dictionary) -> void:
	var key: String = tweak["key"]

	# Label
	var lbl := Label.new()
	lbl.text = tweak["label"]
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.345, 0.537, 0.769))  # RETRO_DARK
	parent.add_child(lbl)

	# Row: slider + value
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var slider := HSlider.new()
	slider.min_value = tweak["min"]
	slider.max_value = tweak["max"]
	slider.step = tweak["step"]
	slider.value = tweak["default"]
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.y = 22

	# Style
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.227, 0.353, 0.541, 0.8)  # RETRO_TEXT (dark background for contrast)
	track.border_color = Color(0.1, 0.2, 0.3, 0.5)
	track.set_border_width_all(1)
	track.set_corner_radius_all(2)
	track.set_content_margin_all(0)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.553, 0.737, 0.918)  # RETRO_SURCONTOUR
	fill.set_corner_radius_all(2)
	fill.set_content_margin_all(0)
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)

	slider.value_changed.connect(_on_slider_changed.bind(key, tweak))
	row.add_child(slider)

	var val_label := Label.new()
	val_label.text = _format_val(tweak["default"], tweak)
	val_label.add_theme_font_size_override("font_size", 11)
	val_label.add_theme_color_override("font_color", Color(0.227, 0.353, 0.541))  # RETRO_TEXT
	val_label.custom_minimum_size.x = 48
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_label)

	_sliders[key] = {"slider": slider, "label": val_label, "tweak": tweak}

func _format_val(val: float, tweak: Dictionary) -> String:
	var suffix: String = tweak.get("suffix", "")
	if tweak["step"] >= 1.0:
		return str(int(val)) + suffix
	else:
		return "%.2f" % val + suffix

func _on_slider_changed(val: float, key: String, tweak: Dictionary) -> void:
	if _sliders.has(key):
		var info: Dictionary = _sliders[key]
		info["label"].text = _format_val(val, tweak)
	# Send to Python
	tweak_changed.emit(key, val)
	var main_node = get_parent()
	if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		main_node.ws.send_text(JSON.stringify({
			"command": "SET_TWEAK",
			"key": key,
			"value": val,
		}))

func _add_toggle(parent: VBoxContainer, toggle: Dictionary) -> void:
	var key: String = toggle["key"]
	var checkbox := CheckBox.new()
	checkbox.text = toggle["label"]
	checkbox.button_pressed = toggle["default"]
	checkbox.add_theme_font_size_override("font_size", 11)
	checkbox.add_theme_color_override("font_color", Color(0.533, 0.784, 0.627) if toggle["default"] else Color(0.878, 0.533, 0.533))
	checkbox.toggled.connect(_on_toggle_changed.bind(key))
	parent.add_child(checkbox)
	_toggles[key] = checkbox

func _on_toggle_changed(pressed: bool, key: String) -> void:
	var val := 1.0 if pressed else 0.0
	# Update checkbox color
	if _toggles.has(key):
		var cb: CheckBox = _toggles[key]
		cb.add_theme_color_override("font_color", Color(0.533, 0.784, 0.627) if pressed else Color(0.878, 0.533, 0.533))
	# Send to Python
	tweak_changed.emit(key, val)
	var main_node = get_parent()
	if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		main_node.ws.send_text(JSON.stringify({
			"command": "SET_TWEAK",
			"key": key,
			"value": val,
		}))
		# Stability toggles require reconnection — tell Python to reconnect
		main_node.ws.send_text(JSON.stringify({
			"command": "FORCE_RECONNECT",
			"reason": key + " toggled " + ("ON" if pressed else "OFF"),
		}))

func _on_reset_all() -> void:
	for tweak in TWEAKS:
		var key: String = tweak["key"]
		if _sliders.has(key):
			var info: Dictionary = _sliders[key]
			info["slider"].value = tweak["default"]
			info["label"].text = _format_val(tweak["default"], tweak)
		# Send reset to Python
		var main_node = get_parent()
		if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			main_node.ws.send_text(JSON.stringify({
				"command": "SET_TWEAK",
				"key": key,
				"value": tweak["default"],
			}))
	# Reset toggles too
	var needs_reconnect := false
	for toggle in STABILITY_TOGGLES:
		var key: String = toggle["key"]
		if _toggles.has(key):
			var cb: CheckBox = _toggles[key]
			var was_on: bool = cb.button_pressed
			cb.set_pressed_no_signal(toggle["default"])
			cb.add_theme_color_override("font_color", Color(0.533, 0.784, 0.627) if toggle["default"] else Color(0.878, 0.533, 0.533))
			if was_on != toggle["default"]:
				needs_reconnect = true
		var main_node = get_parent()
		if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			main_node.ws.send_text(JSON.stringify({
				"command": "SET_TWEAK",
				"key": key,
				"value": 1.0 if toggle["default"] else 0.0,
			}))
	if needs_reconnect:
		var main_node = get_parent()
		if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			main_node.ws.send_text(JSON.stringify({
				"command": "FORCE_RECONNECT",
				"reason": "Reset all toggles",
			}))

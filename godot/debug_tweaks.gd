extends CanvasLayer
## Hidden debug tweaks panel — opened with F2.
## Communicates with Python via WebSocket GET_TWEAKS / SET_TWEAK.
## Minimal and quick: a few sliders for key A.S.C. variables.

signal tweak_changed(key: String, value: float)

var is_open := false
var _bg: ColorRect = null      # Full-screen click catcher (blocks OS passthrough on layered windows)
var _panel: PanelContainer = null
var _sliders := {}   # key → {slider: HSlider, label: Label}

# Each tweak: {key, label, min, max, step, default, suffix}
const TWEAKS := [
	{"key": "suspicion_gain_mult", "label": "⚡ S Gain Speed", "min": 0.1, "max": 5.0, "step": 0.1, "default": 1.0, "suffix": "x"},
	{"key": "suspicion_decay_mult", "label": "💧 S Decay Speed", "min": 0.1, "max": 5.0, "step": 0.1, "default": 1.0, "suffix": "x"},
	{"key": "confidence", "label": "🛡️ Confidence (C)", "min": 0.1, "max": 1.0, "step": 0.05, "default": 1.0, "suffix": ""},
	{"key": "mood_decay_secs", "label": "🎭 Mood Decay", "min": 5.0, "max": 60.0, "step": 5.0, "default": 20.0, "suffix": "s"},
	{"key": "pulse_delay_mult", "label": "📡 Pulse Delay", "min": 0.5, "max": 3.0, "step": 0.25, "default": 1.0, "suffix": "x"},
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
	visible = false
	# Tell Python to re-enable Win32 click-through
	var main_node = get_parent()
	if main_node and main_node.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		main_node.ws.send_text(JSON.stringify({"command": "HIDE_TWEAKS"}))
	# Restore Godot-side passthrough if no other panel is open
	if main_node:
		main_node._safe_restore_passthrough()

func update_values(values: Dictionary) -> void:
	## Called when Python sends TWEAKS_DATA — update slider positions.
	for key in values:
		if _sliders.has(key):
			var info: Dictionary = _sliders[key]
			var slider: HSlider = info["slider"]
			var label: Label = info["label"]
			var tweak: Dictionary = info["tweak"]
			slider.set_value_no_signal(values[key])
			label.text = _format_val(values[key], tweak)

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
	style.bg_color = Color(0.03, 0.03, 0.08, 0.95)
	style.border_color = Color(0.8, 0.4, 0.2, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 5
	_panel.add_theme_stylebox_override("panel", style)

	var panel_w := 300.0
	_panel.custom_minimum_size = Vector2(panel_w, 0)
	_panel.position = Vector2(20, vp.y * 0.15)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_panel.add_child(vbox)

	# Title
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title := Label.new()
	title.text = "🔧  Debug Tweaks"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var hint := Label.new()
	hint.text = "F2"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	title_row.add_child(hint)

	# Separator
	var sep := HSeparator.new()
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.8, 0.4, 0.2, 0.2)
	sep_style.set_content_margin_all(0)
	sep_style.content_margin_top = 3
	sep_style.content_margin_bottom = 3
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# Sliders
	for tweak in TWEAKS:
		_add_slider(vbox, tweak)

	# Reset button
	var reset_btn := Button.new()
	reset_btn.text = "↩️  Reset All"
	reset_btn.custom_minimum_size.y = 28
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.15, 0.08, 0.08, 0.7)
	btn_style.border_color = Color(0.8, 0.3, 0.3, 0.4)
	btn_style.set_border_width_all(1)
	btn_style.set_corner_radius_all(4)
	btn_style.set_content_margin_all(4)
	var btn_hover := StyleBoxFlat.new()
	btn_hover.bg_color = Color(0.25, 0.12, 0.12, 0.8)
	btn_hover.border_color = Color(1.0, 0.4, 0.4, 0.5)
	btn_hover.set_border_width_all(1)
	btn_hover.set_corner_radius_all(4)
	btn_hover.set_content_margin_all(4)
	reset_btn.add_theme_stylebox_override("normal", btn_style)
	reset_btn.add_theme_stylebox_override("hover", btn_hover)
	reset_btn.add_theme_stylebox_override("pressed", btn_hover)
	reset_btn.add_theme_font_size_override("font_size", 11)
	reset_btn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
	reset_btn.pressed.connect(_on_reset_all)
	vbox.add_child(reset_btn)

func _add_slider(parent: VBoxContainer, tweak: Dictionary) -> void:
	var key: String = tweak["key"]

	# Label
	var lbl := Label.new()
	lbl.text = tweak["label"]
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
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
	track.bg_color = Color(0.08, 0.1, 0.18, 0.8)
	track.set_corner_radius_all(3)
	track.set_content_margin_all(0)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.9, 0.5, 0.2, 0.8)
	fill.set_corner_radius_all(3)
	fill.set_content_margin_all(0)
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)

	slider.value_changed.connect(_on_slider_changed.bind(key, tweak))
	row.add_child(slider)

	var val_label := Label.new()
	val_label.text = _format_val(tweak["default"], tweak)
	val_label.add_theme_font_size_override("font_size", 11)
	val_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
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

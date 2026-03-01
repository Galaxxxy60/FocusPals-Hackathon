extends CanvasLayer
## Settings panel using native Godot controls.
## ScrollContainer handles scrolling, VBoxContainer handles layout.
## Adding a new section = just add controls in _build_ui().

signal mic_selected(mic_index: int)
signal panel_closed()
signal api_key_submitted(key: String)
signal language_changed(lang: String)
signal volume_changed(volume: float)
signal session_duration_changed(duration: int)

var is_open := false
var _progress := 0.0
var _mics: Array = []
var _selected_index: int = -1

# API Key state
var _api_key_has_key := false
var _api_key_valid: int = -1  # -1 = unknown, 0 = invalid, 1 = valid
var _api_key_checking := false

# API Usage stats
var _api_usage := {}

# Audio capture for VU meter
var _mic_player: AudioStreamPlayer
var _mic_effect: AudioEffectCapture
var _mic_bus_idx: int = -1
var _vu_level := 0.0

const PANEL_WIDTH := 360.0
const MARGIN_RIGHT := 10.0
const MAX_HEIGHT_RATIO := 0.75
const LANGUAGES := [
	{"code": "fr", "label": "Français"},
	{"code": "en", "label": "English"},
]

# ── UI node references ──
var _panel_container: PanelContainer
var _scroll: ScrollContainer
var _vbox: VBoxContainer
var _session_slider: HSlider
var _session_label: Label
var _mic_container: VBoxContainer
var _vu_bar: ProgressBar
var _api_key_input: LineEdit
var _api_key_btn: Button
var _api_status_label: Label
var _lang_btn: OptionButton
var _volume_slider: HSlider
var _volume_label: Label
var _usage_label: RichTextLabel

# ─── Styles ────────────────────────────────────────────────

func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.04, 0.04, 0.09, 0.96)
	s.border_color = Color(0.3, 0.5, 0.9, 0.5)
	s.set_border_width_all(1)
	s.set_corner_radius_all(8)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.shadow_size = 6
	return s

func _make_input_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.06, 0.12, 0.95)
	s.border_color = Color(0.3, 0.5, 0.8, 0.4)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(6)
	return s

func _make_input_focus_style() -> StyleBoxFlat:
	var s := _make_input_style()
	s.border_color = Color(0.4, 0.7, 1.0, 0.7)
	s.bg_color = Color(0.08, 0.08, 0.16, 0.98)
	return s

func _make_btn_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.12, 0.2, 0.35, 0.8)
	s.border_color = Color(0.3, 0.55, 0.9, 0.4)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(4)
	return s

func _make_btn_hover_style() -> StyleBoxFlat:
	var s := _make_btn_style()
	s.bg_color = Color(0.18, 0.3, 0.5, 0.9)
	s.border_color = Color(0.45, 0.7, 1.0, 0.6)
	return s

func _make_btn_pressed_style() -> StyleBoxFlat:
	var s := _make_btn_style()
	s.bg_color = Color(0.1, 0.35, 0.2, 0.85)
	s.border_color = Color(0.3, 0.9, 0.5, 0.6)
	return s

func _make_mic_btn_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if selected:
		s.bg_color = Color(0.12, 0.35, 0.2, 0.7)
		s.border_color = Color(0.3, 1.0, 0.5, 0.5)
	else:
		s.bg_color = Color(0.06, 0.06, 0.1, 0.3)
		s.border_color = Color(0.2, 0.3, 0.5, 0.2)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(6)
	return s

func _make_mic_btn_hover_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.15, 0.25, 0.45, 0.5)
	s.border_color = Color(0.4, 0.65, 1.0, 0.4)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(6)
	return s

func _make_slider_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.08, 0.1, 0.18, 0.8)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(0)
	return s

func _make_slider_fill_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.3, 0.55, 0.95, 0.85)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(0)
	return s

func _make_separator_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.25, 0.4, 0.7, 0.15)
	s.set_content_margin_all(0)
	s.content_margin_top = 4
	s.content_margin_bottom = 2
	return s

func _make_optionbtn_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.06, 0.12, 0.9)
	s.border_color = Color(0.3, 0.5, 0.8, 0.4)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(6)
	return s

# ─── Ready ─────────────────────────────────────────────────

func _ready() -> void:
	layer = 101
	visible = false
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

func show_settings(mics: Array, selected: int, has_api_key: bool, key_valid: bool = false, lang: String = "fr", volume: float = 1.0, session_duration: int = 50, api_usage: Dictionary = {}) -> void:
	_mics = mics
	_selected_index = selected
	_api_key_has_key = has_api_key
	_api_key_checking = false
	_api_usage = api_usage
	if has_api_key:
		_api_key_valid = 1 if key_valid else 0
	else:
		_api_key_valid = -1

	# Rebuild the entire UI tree every time (clean slate)
	_clear_ui()
	_build_ui(lang, volume, session_duration)

	is_open = true
	visible = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)
	_progress = 0.0
	var tw := create_tween()
	tw.tween_property(self, "_progress", 1.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _mic_player and not _mic_player.playing:
		_match_input_device()
		_mic_player.play()

func close() -> void:
	if not is_open:
		return
	is_open = false
	if _mic_player and _mic_player.playing:
		_mic_player.stop()
	var tw := create_tween()
	tw.tween_property(self, "_progress", 0.0, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		visible = false
		_clear_ui()
		panel_closed.emit()
	)

func update_key_valid(valid: bool) -> void:
	_api_key_valid = 1 if valid else 0
	_api_key_checking = false
	_api_key_has_key = true
	_update_api_status()

# ─── UI Building ──────────────────────────────────────────

func _clear_ui() -> void:
	if _panel_container:
		_panel_container.queue_free()
		_panel_container = null

func _build_ui(lang: String, volume: float, session_duration: int) -> void:
	var vp := get_viewport().get_visible_rect().size
	var max_h := vp.y * MAX_HEIGHT_RATIO

	# ── Root: PanelContainer ──
	_panel_container = PanelContainer.new()
	_panel_container.add_theme_stylebox_override("panel", _make_panel_style())
	_panel_container.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_panel_container.size = Vector2(PANEL_WIDTH, max_h)
	var panel_x := vp.x - PANEL_WIDTH - MARGIN_RIGHT
	var panel_y := vp.y * 0.5 - max_h * 0.5
	panel_y = clampf(panel_y, 10.0, vp.y - max_h - 10.0)
	_panel_container.position = Vector2(panel_x, panel_y)
	add_child(_panel_container)

	# Main VBox inside panel
	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 0)
	_panel_container.add_child(root_vbox)

	# ── Title ──
	var title := Label.new()
	title.text = "⚙️  Réglages"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	root_vbox.add_child(title)
	root_vbox.add_child(_make_sep())

	# ── ScrollContainer (all settings inside) ──
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Style the scrollbar
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.15, 0.7)
	sb.set_corner_radius_all(4)
	_scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	root_vbox.add_child(_scroll)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 2)
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_vbox)

	# ══════ SECTION: Session Duration ══════
	var sess_section := _make_collapsible_section("⏱️  Durée de Session", true)
	_vbox.add_child(sess_section["root"])
	var sess_content: VBoxContainer = sess_section["content"]

	var sess_row := HBoxContainer.new()
	sess_row.add_theme_constant_override("separation", 8)
	sess_content.add_child(sess_row)

	_session_slider = HSlider.new()
	_session_slider.min_value = 5
	_session_slider.max_value = 180
	_session_slider.step = 5
	_session_slider.value = session_duration
	_session_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_session_slider.custom_minimum_size.y = 24
	_session_slider.add_theme_stylebox_override("slider", _make_slider_style())
	_session_slider.add_theme_stylebox_override("grabber_area", _make_slider_fill_style())
	_session_slider.add_theme_stylebox_override("grabber_area_highlight", _make_slider_fill_style())
	_session_slider.value_changed.connect(_on_session_duration_value_changed)
	sess_row.add_child(_session_slider)

	_session_label = Label.new()
	_session_label.text = str(session_duration) + " min"
	_session_label.add_theme_font_size_override("font_size", 12)
	_session_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_session_label.custom_minimum_size.x = 55
	_session_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sess_row.add_child(_session_label)

	# ══════ SECTION: Microphone ══════
	var mic_section := _make_collapsible_section("🎤  Microphone", true)
	_vbox.add_child(mic_section["root"])
	var mic_content: VBoxContainer = mic_section["content"]

	# VU meter
	_vu_bar = ProgressBar.new()
	_vu_bar.min_value = 0.0
	_vu_bar.max_value = 1.0
	_vu_bar.value = 0.0
	_vu_bar.custom_minimum_size = Vector2(0, 8)
	_vu_bar.show_percentage = false
	var vu_bg := StyleBoxFlat.new()
	vu_bg.bg_color = Color(0.04, 0.04, 0.08, 0.9)
	vu_bg.set_corner_radius_all(3)
	_vu_bar.add_theme_stylebox_override("background", vu_bg)
	var vu_fill := StyleBoxFlat.new()
	vu_fill.bg_color = Color(0.1, 0.9, 0.3, 0.9)
	vu_fill.set_corner_radius_all(3)
	_vu_bar.add_theme_stylebox_override("fill", vu_fill)
	mic_content.add_child(_vu_bar)

	# Mic items
	_mic_container = VBoxContainer.new()
	_mic_container.add_theme_constant_override("separation", 3)
	mic_content.add_child(_mic_container)
	for i in _mics.size():
		_add_mic_button(i)

	# ══════ SECTION: API Key ══════
	var api_section := _make_collapsible_section("🔑  Clé API Gemini", false)
	_vbox.add_child(api_section["root"])
	var api_content: VBoxContainer = api_section["content"]

	var api_row := HBoxContainer.new()
	api_row.add_theme_constant_override("separation", 6)
	api_content.add_child(api_row)

	_api_key_input = LineEdit.new()
	_api_key_input.secret = true
	_api_key_input.secret_character = "•"
	_api_key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_key_input.placeholder_text = "Collez votre clé API..."
	_api_key_input.add_theme_stylebox_override("normal", _make_input_style())
	_api_key_input.add_theme_stylebox_override("focus", _make_input_focus_style())
	_api_key_input.add_theme_font_size_override("font_size", 11)
	_api_key_input.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_api_key_input.add_theme_color_override("font_placeholder_color", Color(0.4, 0.4, 0.5))
	_api_key_input.add_theme_color_override("caret_color", Color(0.5, 0.8, 1.0))
	if _api_key_has_key:
		_api_key_input.text = "••••••••••••••••"
	_api_key_input.text_submitted.connect(_on_api_key_submitted)
	api_row.add_child(_api_key_input)

	_api_key_btn = Button.new()
	_api_key_btn.text = "💾"
	_api_key_btn.custom_minimum_size = Vector2(40, 0)
	_api_key_btn.add_theme_stylebox_override("normal", _make_btn_style())
	_api_key_btn.add_theme_stylebox_override("hover", _make_btn_hover_style())
	_api_key_btn.add_theme_stylebox_override("pressed", _make_btn_pressed_style())
	_api_key_btn.add_theme_font_size_override("font_size", 14)
	_api_key_btn.pressed.connect(_on_api_key_btn_pressed)
	api_row.add_child(_api_key_btn)

	_api_status_label = Label.new()
	_api_status_label.add_theme_font_size_override("font_size", 10)
	_update_api_status()
	api_content.add_child(_api_status_label)

	# ══════ SECTION: Language ══════
	var lang_section := _make_collapsible_section("🌐  Langue / Language", false)
	_vbox.add_child(lang_section["root"])
	var lang_content: VBoxContainer = lang_section["content"]

	_lang_btn = OptionButton.new()
	_lang_btn.add_theme_stylebox_override("normal", _make_optionbtn_style())
	_lang_btn.add_theme_stylebox_override("hover", _make_btn_hover_style())
	_lang_btn.add_theme_stylebox_override("pressed", _make_btn_pressed_style())
	_lang_btn.add_theme_font_size_override("font_size", 12)
	_lang_btn.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	var selected_lang_idx := 0
	for i in LANGUAGES.size():
		_lang_btn.add_item(LANGUAGES[i]["label"], i)
		if LANGUAGES[i]["code"] == lang:
			selected_lang_idx = i
	_lang_btn.selected = selected_lang_idx
	_lang_btn.item_selected.connect(_on_language_selected)
	lang_content.add_child(_lang_btn)

	# ══════ SECTION: Volume ══════
	var vol_section := _make_collapsible_section("🔊  Volume Tama", false)
	_vbox.add_child(vol_section["root"])
	var vol_content: VBoxContainer = vol_section["content"]

	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 8)
	vol_content.add_child(vol_row)

	_volume_slider = HSlider.new()
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 1.0
	_volume_slider.step = 0.01
	_volume_slider.value = volume
	_volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_volume_slider.custom_minimum_size.y = 24
	_volume_slider.add_theme_stylebox_override("slider", _make_slider_style())
	_volume_slider.add_theme_stylebox_override("grabber_area", _make_slider_fill_style())
	_volume_slider.add_theme_stylebox_override("grabber_area_highlight", _make_slider_fill_style())
	_volume_slider.value_changed.connect(_on_volume_value_changed)
	vol_row.add_child(_volume_slider)

	_volume_label = Label.new()
	_volume_label.text = str(int(volume * 100)) + "%"
	_volume_label.add_theme_font_size_override("font_size", 12)
	_volume_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.95))
	_volume_label.custom_minimum_size.x = 40
	_volume_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vol_row.add_child(_volume_label)

	# ══════ SECTION: API Usage ══════
	var usage_section := _make_collapsible_section("📊  API Usage", false)
	_vbox.add_child(usage_section["root"])
	var usage_content: VBoxContainer = usage_section["content"]

	_usage_label = RichTextLabel.new()
	_usage_label.bbcode_enabled = true
	_usage_label.fit_content = true
	_usage_label.scroll_active = false
	_usage_label.custom_minimum_size.y = 80
	_usage_label.add_theme_font_size_override("normal_font_size", 10)
	_usage_label.add_theme_color_override("default_color", Color(0.6, 0.7, 0.8))
	_update_usage_text()
	usage_content.add_child(_usage_label)

	# Subtle note
	var note := Label.new()
	note.text = "Depuis le lancement"
	note.add_theme_font_size_override("font_size", 9)
	note.add_theme_color_override("font_color", Color(0.4, 0.45, 0.55, 0.6))
	usage_content.add_child(note)

# ─── Helper: Collapsible Section ──────────────────────────

func _make_collapsible_section(title: String, expanded: bool = true) -> Dictionary:
	## Creates a collapsible section with a clickable header.
	## Returns {"root": VBoxContainer, "content": VBoxContainer, "header": Button}
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 2)

	# Header button
	var header := Button.new()
	var arrow := "▼" if expanded else "▶"
	header.text = arrow + "  " + title
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.custom_minimum_size.y = 28
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = Color(0.06, 0.08, 0.14, 0.6)
	header_style.set_corner_radius_all(4)
	header_style.set_content_margin_all(4)
	header_style.content_margin_left = 8
	var header_hover := StyleBoxFlat.new()
	header_hover.bg_color = Color(0.1, 0.15, 0.25, 0.7)
	header_hover.set_corner_radius_all(4)
	header_hover.set_content_margin_all(4)
	header_hover.content_margin_left = 8
	header.add_theme_stylebox_override("normal", header_style)
	header.add_theme_stylebox_override("hover", header_hover)
	header.add_theme_stylebox_override("pressed", header_hover)
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	header.add_theme_color_override("font_hover_color", Color(0.75, 0.9, 1.0))
	root.add_child(header)

	# Content container
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", 6)
	content_margin.add_theme_constant_override("margin_right", 2)
	content_margin.add_theme_constant_override("margin_top", 2)
	content_margin.add_theme_constant_override("margin_bottom", 4)
	content_margin.add_child(content)
	content_margin.visible = expanded
	root.add_child(content_margin)

	# Separator
	root.add_child(_make_sep())

	# Toggle logic
	header.pressed.connect(func():
		content_margin.visible = not content_margin.visible
		var new_arrow := "▼" if content_margin.visible else "▶"
		header.text = new_arrow + "  " + title
	)

	return {"root": root, "content": content, "header": header}

func _make_sep() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", _make_separator_style())
	sep.add_theme_constant_override("separation", 4)
	return sep

# ─── Mic Buttons ───────────────────────────────────────────

func _add_mic_button(index: int) -> void:
	var mic: Dictionary = _mics[index]
	var mic_index: int = int(mic.get("index", 0))
	var mic_name: String = str(mic.get("name", "?"))
	if mic_name.length() > 30:
		mic_name = mic_name.substr(0, 28) + "…"
	var is_selected := mic_index == _selected_index

	var btn := Button.new()
	btn.text = ("  ✓  " if is_selected else "  ○  ") + mic_name + ("   ACTIF" if is_selected else "")
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size.y = 32
	btn.add_theme_stylebox_override("normal", _make_mic_btn_style(is_selected))
	btn.add_theme_stylebox_override("hover", _make_mic_btn_hover_style())
	btn.add_theme_stylebox_override("pressed", _make_mic_btn_hover_style())
	btn.add_theme_font_size_override("font_size", 11)
	if is_selected:
		btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
	else:
		btn.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	btn.pressed.connect(_on_mic_btn_pressed.bind(mic_index))
	_mic_container.add_child(btn)

# ─── Signal Handlers ──────────────────────────────────────

func _on_session_duration_value_changed(val: float) -> void:
	var dur := int(val)
	_session_label.text = str(dur) + " min"
	session_duration_changed.emit(dur)

func _on_volume_value_changed(val: float) -> void:
	_volume_label.text = str(int(val * 100)) + "%"
	volume_changed.emit(val)

func _on_mic_btn_pressed(mic_idx: int) -> void:
	_selected_index = mic_idx
	mic_selected.emit(mic_idx)
	_match_input_device()
	# Rebuild mic list to update selection visuals
	_rebuild_mic_list()

func _on_api_key_submitted(text: String) -> void:
	var key := text.strip_edges()
	if key.length() > 0 and key != "••••••••••••••••":
		api_key_submitted.emit(key)
		_api_key_has_key = true
		_api_key_valid = -1
		_api_key_checking = true
		_api_key_input.text = "••••••••••••••••"
		_update_api_status()

func _on_api_key_btn_pressed() -> void:
	var key := _api_key_input.text.strip_edges()
	if key.length() > 0 and key != "••••••••••••••••":
		api_key_submitted.emit(key)
		_api_key_has_key = true
		_api_key_valid = -1
		_api_key_checking = true
		_api_key_input.text = "••••••••••••••••"
		_update_api_status()

func _on_language_selected(idx: int) -> void:
	if idx >= 0 and idx < LANGUAGES.size():
		language_changed.emit(LANGUAGES[idx]["code"])

func _rebuild_mic_list() -> void:
	if _mic_container == null:
		return
	for child in _mic_container.get_children():
		child.queue_free()
	# Wait a frame for queue_free to process
	await get_tree().process_frame
	for i in _mics.size():
		_add_mic_button(i)

# ─── API Status ───────────────────────────────────────────

func _update_api_status() -> void:
	if _api_status_label == null:
		return
	if _api_key_checking:
		_api_status_label.text = "⏳ Vérification en cours..."
		_api_status_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.9, 0.8))
	elif _api_key_valid == 1:
		_api_status_label.text = "✅ Clé valide"
		_api_status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4, 0.9))
	elif _api_key_valid == 0:
		_api_status_label.text = "❌ Clé invalide"
		_api_status_label.add_theme_color_override("font_color", Color(0.95, 0.3, 0.25, 0.9))
	else:
		_api_status_label.text = "⚠️ Clé requise pour démarrer"
		_api_status_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.3, 0.8))

# ─── API Usage Text ───────────────────────────────────────

func _update_usage_text() -> void:
	if _usage_label == null:
		return
	var connections := int(_api_usage.get("connections", 0))
	var connect_secs := int(_api_usage.get("connect_secs", 0))
	var screen_pulses := int(_api_usage.get("screen_pulses", 0))
	var function_calls := int(_api_usage.get("function_calls", 0))
	var audio_sent := int(_api_usage.get("audio_sent", 0))
	var audio_recv := int(_api_usage.get("audio_recv", 0))

	var time_str := _format_duration(connect_secs)
	_usage_label.text = ""
	_usage_label.append_text("[color=#8899bb]🔌 Connexions[/color]  [color=#ccddf4]" + str(connections) + "[/color]")
	_usage_label.append_text("      [color=#8899bb]⏱ Temps[/color]  [color=#ccddf4]" + time_str + "[/color]\n")
	_usage_label.append_text("[color=#8899bb]📸 Scans[/color]  [color=#ccddf4]" + _format_number(screen_pulses) + "[/color]")
	_usage_label.append_text("      [color=#8899bb]⚙ Fn calls[/color]  [color=#ccddf4]" + _format_number(function_calls) + "[/color]\n")
	_usage_label.append_text("[color=#8899bb]🎤 Audio ↑[/color]  [color=#ccddf4]" + _format_number(audio_sent) + "[/color]")
	_usage_label.append_text("      [color=#8899bb]🔊 Audio ↓[/color]  [color=#ccddf4]" + _format_number(audio_recv) + "[/color]")

# ─── Process ──────────────────────────────────────────────

func _process(delta: float) -> void:
	if not visible or _panel_container == null:
		return

	# Animate slide-in from the right
	if _panel_container:
		var vp := get_viewport().get_visible_rect().size
		var target_x := vp.x - PANEL_WIDTH - MARGIN_RIGHT
		var off_x := vp.x + 20.0
		_panel_container.position.x = lerpf(off_x, target_x, _progress)
		_panel_container.modulate.a = _progress

	# VU meter
	if is_open:
		_read_vu_level()
		if _vu_bar:
			_vu_bar.value = _vu_level

	# Auto-close if mouse far away
	if is_open and _progress >= 0.9 and _panel_container:
		var mouse := get_viewport().get_mouse_position()
		var pr := Rect2(_panel_container.position, _panel_container.size)
		if mouse.x < pr.position.x - 100 or mouse.y < pr.position.y - 100 or mouse.y > pr.position.y + pr.size.y + 100:
			close()

# ─── Input ────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not is_open:
		return

	# Click outside panel → close
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _panel_container:
			var mouse := get_viewport().get_mouse_position()
			var pr := Rect2(_panel_container.position, _panel_container.size)
			if not pr.has_point(mouse):
				close()
				get_viewport().set_input_as_handled()

# ─── Mic Capture ──────────────────────────────────────────

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

# ─── Formatting Helpers ───────────────────────────────────

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

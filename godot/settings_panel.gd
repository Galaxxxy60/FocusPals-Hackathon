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
signal tama_scale_changed(scale_pct: int)
signal screen_share_toggled(enabled: bool)
signal mic_toggled(enabled: bool)
signal memory_reset()

var is_open := false
var _progress := 0.0
var _mics: Array = []
var _selected_index: int = -1

# API Key state
var _api_key_has_key := false
var _api_key_valid: int = -1  # -1 = unknown, 0 = invalid, 1 = valid
var _api_key_checking := false
var _api_key_hint := ""  # Obfuscated hint (e.g. "••••••••ab1Z")

# API Usage stats
var _api_usage := {}

# Audio capture for VU meter
var _mic_player: AudioStreamPlayer
var _mic_effect: AudioEffectCapture
var _mic_bus_idx: int = -1
var _vu_level := 0.0

# Mic loopback test
var _loopback_player: AudioStreamPlayer
var _loopback_generator: AudioStreamGenerator
var _loopback_playback: AudioStreamGeneratorPlayback
var _is_testing_mic := false
var _test_btn_ref: Button = null  # currently active test button

# Localization
var _L = preload("res://locale.gd").new()

const PANEL_WIDTH := 360.0
const MARGIN_RIGHT := 10.0
const MAX_HEIGHT_RATIO := 0.75
const LANGUAGES := [
	{"code": "fr", "label": "Français"},
	{"code": "en", "label": "English"},
	{"code": "ja", "label": "日本語"},
	{"code": "zh", "label": "中文"},
]

# ── UI node references ──
var _panel_container: PanelContainer
var _scroll: ScrollContainer
var _vbox: VBoxContainer
var _session_slider: HSlider
var _session_label: Label
var _size_slider: HSlider
var _size_label: Label
var _mic_container: VBoxContainer
var _vu_bar: Control  # custom segmented VU meter
var _api_key_input: LineEdit
var _api_key_btn: Button
var _api_status_label: Label
var _lang_btn: OptionButton
var _volume_slider: HSlider
var _volume_label: Label
var _usage_label: RichTextLabel

# Permission toggles
var _screen_share_allowed: bool = true
var _mic_allowed: bool = true
var _screen_share_toggle: CheckButton = null
var _mic_toggle: CheckButton = null
var _memory_empty: bool = true

# ─── Retro Pixel Art Styles (Y2K Pastel Blue) ─────────────
# Palette: #e7eef6 (bg), #80aee3 (border), #8dbcea (surcontour)

const RETRO_BG       := Color(0.906, 0.933, 0.965)  # #e7eef6
const RETRO_BORDER   := Color(0.502, 0.682, 0.890)  # #80aee3
const RETRO_SURCONTOUR := Color(0.553, 0.737, 0.918)  # #8dbcea
const RETRO_ACCENT   := Color(0.659, 0.784, 0.941)  # #a8c8f0
const RETRO_DARK     := Color(0.345, 0.537, 0.769)  # #5889c4
const RETRO_TEXT     := Color(0.227, 0.353, 0.541)  # #3a5a8a
const RETRO_PANEL_BG := Color(0.863, 0.910, 0.957)  # #dce8f4
const RETRO_HOVER    := Color(0.710, 0.816, 0.941)  # #b5d0f0
const RETRO_SUCCESS  := Color(0.533, 0.784, 0.627)  # #88c8a0
const RETRO_DANGER   := Color(0.878, 0.533, 0.533)  # #e08888

func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(RETRO_BG.r, RETRO_BG.g, RETRO_BG.b, 0.97)
	s.border_color = RETRO_BORDER
	s.set_border_width_all(2)
	s.set_corner_radius_all(3)  # Blocky retro corners
	s.shadow_color = Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, 0.3)
	s.shadow_size = 4
	# Double border effect (retro window style)
	s.border_blend = true
	return s

func _make_input_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1.0, 1.0, 1.0, 0.85)
	s.border_color = RETRO_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(6)
	return s

func _make_input_focus_style() -> StyleBoxFlat:
	var s := _make_input_style()
	s.border_color = RETRO_DARK
	s.bg_color = Color(1.0, 1.0, 1.0, 0.95)
	s.set_border_width_all(2)
	return s

func _make_btn_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = RETRO_PANEL_BG
	s.border_color = RETRO_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(4)
	return s

func _make_btn_hover_style() -> StyleBoxFlat:
	var s := _make_btn_style()
	s.bg_color = RETRO_HOVER
	s.border_color = RETRO_DARK
	s.set_border_width_all(2)
	return s

func _make_btn_pressed_style() -> StyleBoxFlat:
	var s := _make_btn_style()
	s.bg_color = Color(RETRO_ACCENT.r, RETRO_ACCENT.g, RETRO_ACCENT.b, 0.9)
	s.border_color = RETRO_DARK
	s.set_border_width_all(2)
	return s

func _make_mic_btn_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if selected:
		s.bg_color = Color(RETRO_HOVER.r, RETRO_HOVER.g, RETRO_HOVER.b, 0.8)
		s.border_color = RETRO_DARK
	else:
		s.bg_color = Color(1.0, 1.0, 1.0, 0.5)
		s.border_color = Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.4)
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(6)
	return s

func _make_mic_btn_hover_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(RETRO_HOVER.r, RETRO_HOVER.g, RETRO_HOVER.b, 0.6)
	s.border_color = RETRO_DARK
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(6)
	return s

func _make_slider_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	# Fond du slider (trough) — plus sombre pour la lisibilité
	s.bg_color = Color(0.227, 0.353, 0.541, 0.8)  # RETRO_TEXT (dark)
	s.border_color = Color(0.1, 0.2, 0.3, 0.5)
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(0)
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s

func _make_slider_fill_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	# Remplissage vif (clair)
	s.bg_color = Color(0.553, 0.737, 0.918)  # RETRO_SURCONTOUR
	s.set_corner_radius_all(2)
	s.set_content_margin_all(0)
	return s

func _make_separator_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.2)
	s.set_content_margin_all(0)
	s.content_margin_top = 4
	s.content_margin_bottom = 2
	return s

func _make_optionbtn_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1.0, 1.0, 1.0, 0.8)
	s.border_color = RETRO_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
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
	# Loopback player for mic test (plays captured mic audio to Master)
	_loopback_generator = AudioStreamGenerator.new()
	_loopback_generator.mix_rate = 44100.0
	_loopback_generator.buffer_length = 0.1
	_loopback_player = AudioStreamPlayer.new()
	_loopback_player.stream = _loopback_generator
	_loopback_player.bus = "Master"
	_loopback_player.volume_db = 0.0
	add_child(_loopback_player)

# ─── Public API ────────────────────────────────────────────

func show_settings(mics: Array, selected: int, has_api_key: bool, key_valid: bool = false, lang: String = "en", volume: float = 1.0, session_duration: int = 50, api_usage: Dictionary = {}, screen_share: bool = true, mic_on: bool = true, tama_scale: int = 100, key_hint: String = "", memory_empty: bool = true) -> void:
	_mics = mics
	_selected_index = selected
	_api_key_has_key = has_api_key
	_api_key_checking = false
	_api_usage = api_usage
	_screen_share_allowed = screen_share
	_mic_allowed = mic_on
	_api_key_hint = key_hint
	_memory_empty = memory_empty
	if has_api_key:
		_api_key_valid = 1 if key_valid else 0
	else:
		_api_key_valid = -1

	# Rebuild the entire UI tree every time (clean slate)
	_clear_ui()
	_build_ui(lang, volume, session_duration, tama_scale)

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
	_stop_mic_test()
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

func _build_ui(lang: String, volume: float, session_duration: int, tama_scale: int = 100) -> void:
	_L.set_lang(lang)
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

	# --- Title Row (Retro Window Title Bar) ---
	var title_panel := PanelContainer.new()
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = RETRO_TEXT  # Dark blue title bar
	t_style.border_color = RETRO_DARK
	t_style.set_border_width_all(1)
	t_style.content_margin_left = 8
	t_style.content_margin_right = 8
	t_style.content_margin_top = 4
	t_style.content_margin_bottom = 4
	title_panel.add_theme_stylebox_override("panel", t_style)
	root_vbox.add_child(title_panel)

	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 0)
	title_panel.add_child(title_bar)

	var title := Label.new()
	title.text = _L.t("settings_title")
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(1, 1, 1))  # White text on dark bar
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(24, 24)
	var close_style := StyleBoxFlat.new()
	close_style.bg_color = Color(0.8, 0.85, 0.9)  # Light gray-blue button
	close_style.border_color = Color(1, 1, 1)     # Inner light highlight
	close_style.set_border_width_all(1)
	close_style.set_corner_radius_all(2)
	close_style.set_content_margin_all(2)
	var close_hover := StyleBoxFlat.new()
	close_hover.bg_color = Color(RETRO_DANGER.r, RETRO_DANGER.g, RETRO_DANGER.b, 0.9)
	close_hover.border_color = Color(1, 1, 1)
	close_hover.set_border_width_all(1)
	close_hover.set_corner_radius_all(2)
	close_hover.set_content_margin_all(2)
	close_btn.add_theme_stylebox_override("normal", close_style)
	close_btn.add_theme_stylebox_override("hover", close_hover)
	close_btn.add_theme_stylebox_override("pressed", close_hover)
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	close_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	close_btn.pressed.connect(close)
	title_bar.add_child(close_btn)

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

	# Margin container for scroll content (replaces panel content_margin)
	var scroll_margin := MarginContainer.new()
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_theme_constant_override("margin_left", 14)
	scroll_margin.add_theme_constant_override("margin_right", 14)
	scroll_margin.add_theme_constant_override("margin_top", 6)
	scroll_margin.add_theme_constant_override("margin_bottom", 10)
	_scroll.add_child(scroll_margin)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 2)
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_child(_vbox)

	# ══════ SECTION: Session ══════
	var sess_section := _make_collapsible_section(_L.t("section_session"), false)
	_vbox.add_child(sess_section["root"])
	var sess_content: VBoxContainer = sess_section["content"]

	var sess_lbl := Label.new()
	sess_lbl.text = _L.t("deep_work_duration")
	sess_lbl.add_theme_font_size_override("font_size", 10)
	sess_lbl.add_theme_color_override("font_color", RETRO_DARK)
	sess_content.add_child(sess_lbl)

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
	_session_label.add_theme_color_override("font_color", RETRO_TEXT)
	_session_label.custom_minimum_size.x = 55
	_session_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sess_row.add_child(_session_label)

	# ══════ SECTION: Audio (Mic + Volume) ══════
	var audio_section := _make_collapsible_section(_L.t("section_audio"), false)
	_vbox.add_child(audio_section["root"])
	var audio_content: VBoxContainer = audio_section["content"]

	# ── Sub: Microphone ──
	var mic_lbl := Label.new()
	mic_lbl.text = _L.t("microphone")
	mic_lbl.add_theme_font_size_override("font_size", 10)
	mic_lbl.add_theme_color_override("font_color", RETRO_DARK)
	audio_content.add_child(mic_lbl)

	# VU meter (segmented bars)
	_vu_bar = _SegmentedVU.new()
	_vu_bar.custom_minimum_size = Vector2(0, 14)
	audio_content.add_child(_vu_bar)

	# Mic items
	_mic_container = VBoxContainer.new()
	_mic_container.add_theme_constant_override("separation", 3)
	audio_content.add_child(_mic_container)
	for i in _mics.size():
		_add_mic_button(i)

	# ── Sub: Volume ──
	audio_content.add_child(_make_sub_sep())

	var vol_lbl := Label.new()
	vol_lbl.text = _L.t("volume_tama")
	vol_lbl.add_theme_font_size_override("font_size", 10)
	vol_lbl.add_theme_color_override("font_color", RETRO_DARK)
	audio_content.add_child(vol_lbl)

	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 8)
	audio_content.add_child(vol_row)

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
	_volume_label.add_theme_color_override("font_color", RETRO_TEXT)
	_volume_label.custom_minimum_size.x = 40
	_volume_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vol_row.add_child(_volume_label)

	# ══════ SECTION: API (Key + Usage) ══════
	var api_section := _make_collapsible_section(_L.t("section_api"), false)
	_vbox.add_child(api_section["root"])
	var api_content: VBoxContainer = api_section["content"]

	# ── Sub: API Key ──
	var key_lbl := Label.new()
	key_lbl.text = _L.t("api_key_label")
	key_lbl.add_theme_font_size_override("font_size", 10)
	key_lbl.add_theme_color_override("font_color", RETRO_DARK)
	api_content.add_child(key_lbl)

	var api_row := HBoxContainer.new()
	api_row.add_theme_constant_override("separation", 6)
	api_content.add_child(api_row)

	_api_key_input = LineEdit.new()
	_api_key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_key_input.placeholder_text = _L.t("api_key_placeholder")
	_api_key_input.add_theme_stylebox_override("normal", _make_input_style())
	_api_key_input.add_theme_stylebox_override("focus", _make_input_focus_style())
	_api_key_input.add_theme_font_size_override("font_size", 11)
	_api_key_input.add_theme_color_override("font_color", RETRO_TEXT)
	_api_key_input.add_theme_color_override("font_placeholder_color", Color(RETRO_DARK.r, RETRO_DARK.g, RETRO_DARK.b, 0.5))
	_api_key_input.add_theme_color_override("caret_color", RETRO_DARK)
	if _api_key_has_key:
		if _api_key_hint.length() > 0:
			# Show obfuscated hint so user can identify the key (e.g. "••••••••ab1Z")
			_api_key_input.text = _api_key_hint
			_api_key_input.secret = false
		else:
			_api_key_input.text = "••••••••••••••••"
			_api_key_input.secret = true
			_api_key_input.secret_character = "•"
	else:
		_api_key_input.secret = true
		_api_key_input.secret_character = "•"
	_api_key_input.text_submitted.connect(_on_api_key_submitted)
	# Clear hint on focus so user can paste a new key
	_api_key_input.focus_entered.connect(_on_api_key_focus)
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

	# ── Sub: Usage ──
	api_content.add_child(_make_sub_sep())

	var usage_lbl := Label.new()
	usage_lbl.text = _L.t("api_usage_label")
	usage_lbl.add_theme_font_size_override("font_size", 10)
	usage_lbl.add_theme_color_override("font_color", RETRO_DARK)
	api_content.add_child(usage_lbl)

	_usage_label = RichTextLabel.new()
	_usage_label.bbcode_enabled = true
	_usage_label.fit_content = true
	_usage_label.scroll_active = false
	_usage_label.custom_minimum_size.y = 80
	_usage_label.add_theme_font_size_override("normal_font_size", 10)
	_usage_label.add_theme_color_override("default_color", RETRO_TEXT)
	_update_usage_text()
	api_content.add_child(_usage_label)

	var note := Label.new()
	note.text = _L.t("api_since_launch")
	note.add_theme_font_size_override("font_size", 9)
	note.add_theme_color_override("font_color", Color(RETRO_DARK.r, RETRO_DARK.g, RETRO_DARK.b, 0.6))
	api_content.add_child(note)

	# ══════ SECTION: General (Language + Tama Size) ══════
	var gen_section := _make_collapsible_section(_L.t("section_general"), false)
	_vbox.add_child(gen_section["root"])
	_vbox.move_child(gen_section["root"], 0)  # Move to TOP
	var gen_content: VBoxContainer = gen_section["content"]

	# ── Sub: Language ──
	var lang_lbl := Label.new()
	lang_lbl.text = _L.t("language_label")
	lang_lbl.add_theme_font_size_override("font_size", 10)
	lang_lbl.add_theme_color_override("font_color", RETRO_DARK)
	gen_content.add_child(lang_lbl)

	_lang_btn = OptionButton.new()
	_lang_btn.add_theme_stylebox_override("normal", _make_optionbtn_style())
	_lang_btn.add_theme_stylebox_override("hover", _make_btn_hover_style())
	_lang_btn.add_theme_stylebox_override("pressed", _make_btn_pressed_style())
	_lang_btn.add_theme_font_size_override("font_size", 12)
	_lang_btn.add_theme_color_override("font_color", RETRO_TEXT)
	var selected_lang_idx := 0
	for i in LANGUAGES.size():
		_lang_btn.add_item(LANGUAGES[i]["label"], i)
		if LANGUAGES[i]["code"] == lang:
			selected_lang_idx = i
	_lang_btn.selected = selected_lang_idx
	_lang_btn.item_selected.connect(_on_language_selected)
	gen_content.add_child(_lang_btn)

	# ── Sub: Tama Size ──
	gen_content.add_child(_make_sub_sep())

	var size_lbl := Label.new()
	size_lbl.text = _L.t("tama_size")
	size_lbl.add_theme_font_size_override("font_size", 10)
	size_lbl.add_theme_color_override("font_color", RETRO_DARK)
	gen_content.add_child(size_lbl)

	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	gen_content.add_child(size_row)

	# Font Awesome person silhouette (U+F183)
	var fa_font := FontFile.new()
	fa_font.load_dynamic_font("res://fa-solid-900.ttf")
	var person_char := char(0xF183)

	# Small silhouette to the left
	var icon_small := Label.new()
	icon_small.text = person_char
	icon_small.add_theme_font_override("font", fa_font)
	icon_small.add_theme_font_size_override("font_size", 12)
	icon_small.add_theme_color_override("font_color", Color(RETRO_DARK.r, RETRO_DARK.g, RETRO_DARK.b, 0.7))
	icon_small.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	size_row.add_child(icon_small)

	_size_slider = HSlider.new()
	_size_slider.min_value = 50
	_size_slider.max_value = 150
	_size_slider.step = 10
	_size_slider.value = tama_scale
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_slider.custom_minimum_size.y = 24
	_size_slider.add_theme_stylebox_override("slider", _make_slider_style())
	_size_slider.add_theme_stylebox_override("grabber_area", _make_slider_fill_style())
	_size_slider.add_theme_stylebox_override("grabber_area_highlight", _make_slider_fill_style())
	_size_slider.value_changed.connect(_on_tama_scale_value_changed)
	size_row.add_child(_size_slider)

	# Big silhouette to the right
	var icon_big := Label.new()
	icon_big.text = person_char
	icon_big.add_theme_font_override("font", fa_font)
	icon_big.add_theme_font_size_override("font_size", 20)
	icon_big.add_theme_color_override("font_color", Color(RETRO_TEXT.r, RETRO_TEXT.g, RETRO_TEXT.b, 0.9))
	icon_big.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	size_row.add_child(icon_big)

	_size_label = Label.new()
	_size_label.text = str(tama_scale) + "%"
	_size_label.add_theme_font_size_override("font_size", 12)
	_size_label.add_theme_color_override("font_color", RETRO_TEXT)
	_size_label.custom_minimum_size.x = 42
	_size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	size_row.add_child(_size_label)

	# ══════ SECTION: Permissions (Screen Share + Mic) ══════
	var perm_section := _make_collapsible_section(_L.t("section_permissions"), false)
	_vbox.add_child(perm_section["root"])
	var perm_content: VBoxContainer = perm_section["content"]

	# ── Screen Share Toggle ──
	var screen_row := HBoxContainer.new()
	screen_row.add_theme_constant_override("separation", 8)
	perm_content.add_child(screen_row)

	var screen_lbl_box := VBoxContainer.new()
	screen_lbl_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen_lbl_box.add_theme_constant_override("separation", 0)
	screen_row.add_child(screen_lbl_box)

	var screen_title := Label.new()
	screen_title.text = _L.t("screen_share_title")
	screen_title.add_theme_font_size_override("font_size", 11)
	screen_title.add_theme_color_override("font_color", RETRO_TEXT)
	screen_lbl_box.add_child(screen_title)

	var screen_desc := Label.new()
	screen_desc.text = _L.t("screen_share_desc")
	screen_desc.add_theme_font_size_override("font_size", 9)
	screen_desc.add_theme_color_override("font_color", Color(RETRO_DARK.r, RETRO_DARK.g, RETRO_DARK.b, 0.7))
	screen_lbl_box.add_child(screen_desc)

	_screen_share_toggle = CheckButton.new()
	_screen_share_toggle.button_pressed = _screen_share_allowed
	_screen_share_toggle.custom_minimum_size = Vector2(50, 28)
	_screen_share_toggle.add_theme_color_override("font_color", RETRO_TEXT)
	_screen_share_toggle.toggled.connect(_on_screen_share_toggled)
	screen_row.add_child(_screen_share_toggle)

	perm_content.add_child(_make_sub_sep())

	# ── Microphone Toggle ──
	var mic_row := HBoxContainer.new()
	mic_row.add_theme_constant_override("separation", 8)
	perm_content.add_child(mic_row)

	var mic_lbl_box := VBoxContainer.new()
	mic_lbl_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mic_lbl_box.add_theme_constant_override("separation", 0)
	mic_row.add_child(mic_lbl_box)

	var mic_title := Label.new()
	mic_title.text = _L.t("mic_permission_title")
	mic_title.add_theme_font_size_override("font_size", 11)
	mic_title.add_theme_color_override("font_color", RETRO_TEXT)
	mic_lbl_box.add_child(mic_title)

	var mic_desc := Label.new()
	mic_desc.text = _L.t("mic_permission_desc")
	mic_desc.add_theme_font_size_override("font_size", 9)
	mic_desc.add_theme_color_override("font_color", Color(RETRO_DARK.r, RETRO_DARK.g, RETRO_DARK.b, 0.7))
	mic_lbl_box.add_child(mic_desc)

	_mic_toggle = CheckButton.new()
	_mic_toggle.button_pressed = _mic_allowed
	_mic_toggle.custom_minimum_size = Vector2(50, 28)
	_mic_toggle.add_theme_color_override("font_color", RETRO_TEXT)
	_mic_toggle.toggled.connect(_on_mic_toggled)
	mic_row.add_child(_mic_toggle)

	# ══════ SECTION: Danger Zone (Reset) ══════
	var danger_section := _make_collapsible_section(_L.t("section_data"), false)
	_vbox.add_child(danger_section["root"])
	var danger_content: VBoxContainer = danger_section["content"]

	var reset_desc := Label.new()
	reset_desc.text = _L.t("reset_memory_desc")
	reset_desc.add_theme_font_size_override("font_size", 9)
	reset_desc.add_theme_color_override("font_color", Color(RETRO_DANGER.r, RETRO_DANGER.g, RETRO_DANGER.b, 0.8))
	reset_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	danger_content.add_child(reset_desc)

	var reset_btn := Button.new()
	reset_btn.custom_minimum_size = Vector2(0, 32)
	var danger_style := StyleBoxFlat.new()
	var danger_hover := StyleBoxFlat.new()

	if _memory_empty:
		# Memory already empty → greyed out
		reset_btn.text = "💾  Memory is empty"
		reset_btn.disabled = true
		danger_style.bg_color = Color(0.1, 0.1, 0.12, 0.4)
		danger_style.border_color = Color(0.25, 0.25, 0.3, 0.3)
		danger_hover = danger_style
		reset_btn.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
		reset_btn.add_theme_color_override("font_disabled_color", Color(0.4, 0.4, 0.45))
	else:
		reset_btn.text = "🗑️  Reset Memory"
		danger_style.bg_color = Color(0.25, 0.08, 0.08, 0.7)
		danger_style.border_color = Color(0.7, 0.2, 0.2, 0.4)
		danger_hover.bg_color = Color(0.4, 0.1, 0.1, 0.85)
		danger_hover.border_color = Color(1.0, 0.3, 0.3, 0.6)
		danger_hover.set_border_width_all(1)
		danger_hover.set_corner_radius_all(4)
		danger_hover.set_content_margin_all(4)
		reset_btn.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
		reset_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.6, 0.6))

	danger_style.set_border_width_all(1)
	danger_style.set_corner_radius_all(4)
	danger_style.set_content_margin_all(4)
	reset_btn.add_theme_stylebox_override("normal", danger_style)
	reset_btn.add_theme_stylebox_override("hover", danger_hover)
	reset_btn.add_theme_stylebox_override("pressed", danger_hover)
	reset_btn.add_theme_stylebox_override("disabled", danger_style)
	reset_btn.add_theme_font_size_override("font_size", 11)
	var _reset_confirmed := false
	reset_btn.pressed.connect(func():
		if _memory_empty:
			return
		if not _reset_confirmed:
			_reset_confirmed = true
			reset_btn.text = "⚠️  Click again to confirm"
			reset_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			# Auto-cancel after 3s
			var tw := create_tween()
			tw.tween_interval(3.0)
			tw.tween_callback(func():
				if is_instance_valid(reset_btn):
					_reset_confirmed = false
					reset_btn.text = "🗑️  Reset Memory"
					reset_btn.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
			)
		else:
			_reset_confirmed = false
			reset_btn.text = "✓  Memory Reset!"
			reset_btn.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
			# Play erased sound at low volume
			var sfx := AudioStreamPlayer.new()
			sfx.stream = load("res://erased.ogg")
			sfx.volume_db = -18.0
			add_child(sfx)
			sfx.play()
			sfx.finished.connect(sfx.queue_free)
			# Grey out button after reset
			_memory_empty = true
			reset_btn.disabled = true
			var grey_style := StyleBoxFlat.new()
			grey_style.bg_color = Color(0.1, 0.1, 0.12, 0.4)
			grey_style.border_color = Color(0.25, 0.25, 0.3, 0.3)
			grey_style.set_border_width_all(1)
			grey_style.set_corner_radius_all(4)
			grey_style.set_content_margin_all(4)
			reset_btn.add_theme_stylebox_override("normal", grey_style)
			reset_btn.add_theme_stylebox_override("disabled", grey_style)
			memory_reset.emit()
			# Change text after a beat
			var tw2 := create_tween()
			tw2.tween_interval(1.5)
			tw2.tween_callback(func():
				if is_instance_valid(reset_btn):
					reset_btn.text = "💾  Memory is empty"
					reset_btn.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
					reset_btn.add_theme_color_override("font_disabled_color", Color(0.4, 0.4, 0.45))
			)
	)
	danger_content.add_child(reset_btn)

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
	header_style.bg_color = Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, 0.3)
	header_style.border_color = Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.3)
	header_style.set_border_width_all(1)
	header_style.set_corner_radius_all(2)
	header_style.set_content_margin_all(4)
	header_style.content_margin_left = 8
	var header_hover := StyleBoxFlat.new()
	header_hover.bg_color = Color(RETRO_HOVER.r, RETRO_HOVER.g, RETRO_HOVER.b, 0.5)
	header_hover.border_color = RETRO_BORDER
	header_hover.set_border_width_all(1)
	header_hover.set_corner_radius_all(2)
	header_hover.set_content_margin_all(4)
	header_hover.content_margin_left = 8
	header.add_theme_stylebox_override("normal", header_style)
	header.add_theme_stylebox_override("hover", header_hover)
	header.add_theme_stylebox_override("pressed", header_hover)
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", RETRO_DARK)
	header.add_theme_color_override("font_hover_color", RETRO_TEXT)
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

func _make_sub_sep() -> HSeparator:
	## Lighter separator for sub-sections within a collapsible section
	var sep := HSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.12)
	style.set_content_margin_all(0)
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	sep.add_theme_stylebox_override("separator", style)
	sep.add_theme_constant_override("separation", 2)
	return sep

# ─── Mic Buttons ───────────────────────────────────────────

func _add_mic_button(index: int) -> void:
	var mic: Dictionary = _mics[index]
	var mic_index: int = int(mic.get("index", 0))
	var mic_name: String = str(mic.get("name", "?"))
	if mic_name.length() > 30:
		mic_name = mic_name.substr(0, 28) + "…"
	var is_selected := mic_index == _selected_index

	# Row: [mic select button] [test button]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_mic_container.add_child(row)

	var btn := Button.new()
	btn.text = ("  ✓  " if is_selected else "  ○  ") + mic_name + ("   " + _L.t("mic_active") if is_selected else "")
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size.y = 32
	btn.add_theme_stylebox_override("normal", _make_mic_btn_style(is_selected))
	btn.add_theme_stylebox_override("hover", _make_mic_btn_hover_style())
	btn.add_theme_stylebox_override("pressed", _make_mic_btn_hover_style())
	btn.add_theme_font_size_override("font_size", 11)
	if is_selected:
		btn.add_theme_color_override("font_color", RETRO_DARK)
	else:
		btn.add_theme_color_override("font_color", RETRO_TEXT)
	btn.pressed.connect(_on_mic_btn_pressed.bind(mic_index))
	row.add_child(btn)

	# Test button
	var test_btn := Button.new()
	test_btn.text = "🔊"
	test_btn.tooltip_text = _L.t("test_mic_tooltip")
	test_btn.custom_minimum_size = Vector2(36, 32)
	var test_style := _make_btn_style()
	test_style.bg_color = Color(0.08, 0.12, 0.22, 0.7)
	test_btn.add_theme_stylebox_override("normal", test_style)
	test_btn.add_theme_stylebox_override("hover", _make_btn_hover_style())
	test_btn.add_theme_stylebox_override("pressed", _make_btn_pressed_style())
	test_btn.add_theme_font_size_override("font_size", 13)
	test_btn.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
	test_btn.pressed.connect(_on_test_mic_pressed.bind(mic_index, test_btn))
	row.add_child(test_btn)

# ─── Signal Handlers ──────────────────────────────────────

func _on_session_duration_value_changed(val: float) -> void:
	var dur := int(val)
	_session_label.text = str(dur) + " min"
	session_duration_changed.emit(dur)

func _on_tama_scale_value_changed(val: float) -> void:
	var pct := int(val)
	_size_label.text = str(pct) + "%"
	tama_scale_changed.emit(pct)

func _on_volume_value_changed(val: float) -> void:
	_volume_label.text = str(int(val * 100)) + "%"
	volume_changed.emit(val)

func _on_mic_btn_pressed(mic_idx: int) -> void:
	_selected_index = mic_idx
	_stop_mic_test()
	mic_selected.emit(mic_idx)
	_match_input_device()
	# Rebuild mic list to update selection visuals
	_rebuild_mic_list()

func _is_hint_or_dots(text: String) -> bool:
	"""Check if text is the obfuscated hint or generic dots (not a real key)."""
	if text == "••••••••••••••••":
		return true
	if _api_key_hint.length() > 0 and text == _api_key_hint:
		return true
	return false

func _on_api_key_focus() -> void:
	"""When user clicks the field, clear the hint so they can paste a new key."""
	if _api_key_input == null:
		return
	if _is_hint_or_dots(_api_key_input.text):
		_api_key_input.text = ""
		_api_key_input.secret = true
		_api_key_input.secret_character = "•"

func _on_api_key_submitted(text: String) -> void:
	var key := text.strip_edges()
	if key.length() > 0 and not _is_hint_or_dots(key):
		api_key_submitted.emit(key)
		_api_key_has_key = true
		_api_key_valid = -1
		_api_key_checking = true
		_api_key_input.secret = false
		_api_key_input.text = "••••••••" + key.right(4) if key.length() > 4 else "••••••••••••••••"
		_api_key_hint = _api_key_input.text
		_update_api_status()

func _on_api_key_btn_pressed() -> void:
	var key := _api_key_input.text.strip_edges()
	if key.length() > 0 and not _is_hint_or_dots(key):
		api_key_submitted.emit(key)
		_api_key_has_key = true
		_api_key_valid = -1
		_api_key_checking = true
		_api_key_input.secret = false
		_api_key_input.text = "••••••••" + key.right(4) if key.length() > 4 else "••••••••••••••••"
		_api_key_hint = _api_key_input.text
		_update_api_status()

func _on_language_selected(idx: int) -> void:
	if idx >= 0 and idx < LANGUAGES.size():
		var new_lang: String = str(LANGUAGES[idx]["code"])
		language_changed.emit(new_lang)
		# Live rebuild: re-create the entire UI with the new language
		if is_open and _panel_container:
			var vol := _volume_slider.value if _volume_slider else 1.0
			var sess := int(_session_slider.value) if _session_slider else 50
			var scale := int(_size_slider.value) if _size_slider else 100
			_clear_ui()
			_build_ui(new_lang, vol, sess, scale)

func _on_screen_share_toggled(enabled: bool) -> void:
	_screen_share_allowed = enabled
	screen_share_toggled.emit(enabled)

func _on_mic_toggled(enabled: bool) -> void:
	_mic_allowed = enabled
	mic_toggled.emit(enabled)

func _rebuild_mic_list() -> void:
	if _mic_container == null:
		return
	for child in _mic_container.get_children():
		child.queue_free()
	# Wait a frame for queue_free to process
	await get_tree().process_frame
	for i in _mics.size():
		_add_mic_button(i)

# ─── Mic Test (Loopback) ─────────────────────────────────

func _on_test_mic_pressed(mic_idx: int, btn: Button) -> void:
	# If already testing this mic, stop
	if _is_testing_mic and _test_btn_ref == btn:
		_stop_mic_test()
		return
	# Stop any existing test first
	_stop_mic_test()
	# Select this mic for capture
	_selected_index = mic_idx
	mic_selected.emit(mic_idx)
	_match_input_device()
	# Start loopback
	_is_testing_mic = true
	_test_btn_ref = btn
	_style_test_btn_active(btn, true)
	if _loopback_player and not _loopback_player.playing:
		_loopback_player.play()
		_loopback_playback = _loopback_player.get_stream_playback()
	# Rebuild to update selection visuals
	# (skip — would destroy buttons; just update styles inline)

func _stop_mic_test() -> void:
	if not _is_testing_mic:
		return
	_is_testing_mic = false
	if _loopback_player and _loopback_player.playing:
		_loopback_player.stop()
	_loopback_playback = null
	if _test_btn_ref and is_instance_valid(_test_btn_ref):
		_style_test_btn_active(_test_btn_ref, false)
	_test_btn_ref = null

func _style_test_btn_active(btn: Button, active: bool) -> void:
	if active:
		var active_style := _make_btn_style()
		active_style.bg_color = Color(0.1, 0.4, 0.2, 0.85)
		active_style.border_color = Color(0.3, 1.0, 0.5, 0.6)
		btn.add_theme_stylebox_override("normal", active_style)
		btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
		btn.text = "🔇"
	else:
		var normal_style := _make_btn_style()
		normal_style.bg_color = Color(0.08, 0.12, 0.22, 0.7)
		btn.add_theme_stylebox_override("normal", normal_style)
		btn.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
		btn.text = "🔊"

func _feed_loopback() -> void:
	## Feed captured mic frames into the loopback generator for playback.
	if _mic_effect == null or _loopback_playback == null:
		return
	var frames := _mic_effect.get_frames_available()
	if frames <= 0:
		return
	# Read frames (shared with VU meter — VU will also read, so we use a
	# reasonable chunk).  The capture buffer is consumed once, so we process
	# here and also update VU from the same data.
	var buf := _mic_effect.get_buffer(mini(frames, 2048))
	var can_push := _loopback_playback.get_frames_available()
	var to_push := mini(buf.size(), can_push)
	for i in to_push:
		_loopback_playback.push_frame(buf[i])

# ─── API Status ───────────────────────────────────────────

func _update_api_status() -> void:
	if _api_status_label == null:
		return
	if _api_key_checking:
		_api_status_label.text = _L.t("api_status_checking")
		_api_status_label.add_theme_color_override("font_color", RETRO_DARK)
	elif _api_key_valid == 1:
		_api_status_label.text = _L.t("api_status_valid")
		_api_status_label.add_theme_color_override("font_color", RETRO_SUCCESS)
	elif _api_key_valid == 0:
		_api_status_label.text = _L.t("api_status_invalid")
		_api_status_label.add_theme_color_override("font_color", RETRO_DANGER)
	else:
		_api_status_label.text = _L.t("api_status_required")
		_api_status_label.add_theme_color_override("font_color", Color(0.9, 0.6, 0.4, 0.9))

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
	var lite_calls := int(_api_usage.get("lite_calls", 0))
	var lite_in := int(_api_usage.get("lite_input_tokens", 0))
	var lite_out := int(_api_usage.get("lite_output_tokens", 0))
	var lite_errors := int(_api_usage.get("lite_errors", 0))

	var time_str := _format_duration(connect_secs)
	_usage_label.text = ""
	_usage_label.append_text("[color=#5889c4]🔌 " + _L.t("usage_connections") + "[/color]  [color=#3a5a8a]" + str(connections) + "[/color]")
	_usage_label.append_text("      [color=#5889c4]⏱ " + _L.t("usage_time") + "[/color]  [color=#3a5a8a]" + time_str + "[/color]\n")
	_usage_label.append_text("[color=#5889c4]📸 " + _L.t("usage_scans") + "[/color]  [color=#3a5a8a]" + _format_number(screen_pulses) + "[/color]")
	_usage_label.append_text("      [color=#5889c4]⚙ Fn calls[/color]  [color=#3a5a8a]" + _format_number(function_calls) + "[/color]\n")
	_usage_label.append_text("[color=#5889c4]🎤 Audio ↑[/color]  [color=#3a5a8a]" + _format_number(audio_sent) + "[/color]")
	_usage_label.append_text("      [color=#5889c4]🔊 Audio ↓[/color]  [color=#3a5a8a]" + _format_number(audio_recv) + "[/color]\n")
	# Flash-Lite 3.1 secondary agent stats
	if lite_calls > 0:
		_usage_label.append_text("[color=#80aee3]⚡ Lite[/color]  [color=#5889c4]" + _format_number(lite_calls) + " calls[/color]")
		_usage_label.append_text("  [color=#80aee3]↑[/color] [color=#5889c4]" + _format_number(lite_in) + "[/color]")
		_usage_label.append_text("  [color=#80aee3]↓[/color] [color=#5889c4]" + _format_number(lite_out) + " tok[/color]")
		if lite_errors > 0:
			_usage_label.append_text("  [color=#e08888]⚠ " + str(lite_errors) + "[/color]")

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

	# VU meter + loopback
	if is_open:
		if _is_testing_mic:
			_feed_loopback_and_vu()
		else:
			_read_vu_level()
		if _vu_bar:
			_vu_bar.set_meta("level", _vu_level)
			_vu_bar.queue_redraw()

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

func _feed_loopback_and_vu() -> void:
	## Combined: read mic frames, feed loopback AND update VU from the same buffer.
	if _mic_effect == null:
		return
	var frames := _mic_effect.get_frames_available()
	if frames <= 0:
		_vu_level = lerp(_vu_level, 0.0, 0.1)
		return
	var buf := _mic_effect.get_buffer(mini(frames, 2048))
	# VU
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
	# Loopback
	if _loopback_playback != null:
		var can_push := _loopback_playback.get_frames_available()
		var to_push := mini(buf.size(), can_push)
		for i in to_push:
			_loopback_playback.push_frame(buf[i])

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

# ─── Segmented VU Meter (inner class) ─────────────────────

class _SegmentedVU extends Control:
	## Draws N small rectangles that go from green → yellow → orange → red.
	## Inactive segments are drawn as dark semi-transparent ghost bars.
	const SEGMENT_COUNT := 20
	const GAP := 2.0
	const CORNER := 1.5

	# Color stops: segment 0..19 mapped to a gradient
	static func _seg_color(i: int) -> Color:
		var t := float(i) / float(SEGMENT_COUNT - 1)
		if t < 0.5:
			# green → yellow
			return Color(0.15 + t * 1.7, 0.9, 0.2, 1.0)
		elif t < 0.75:
			# yellow → orange
			var u := (t - 0.5) / 0.25
			return Color(1.0, 0.9 - u * 0.5, 0.15, 1.0)
		else:
			# orange → red
			var u := (t - 0.75) / 0.25
			return Color(1.0, 0.4 - u * 0.3, 0.1, 1.0)

	func _draw() -> void:
		var level: float = get_meta("level", 0.0)
		var w := size.x
		var h := size.y
		var seg_w := (w - GAP * (SEGMENT_COUNT - 1)) / float(SEGMENT_COUNT)
		if seg_w < 2.0:
			seg_w = 2.0

		var active_count := int(level * SEGMENT_COUNT)
		# Partial brightness on the next segment
		var partial := (level * SEGMENT_COUNT) - float(active_count)

		for i in SEGMENT_COUNT:
			var x := float(i) * (seg_w + GAP)
			var rect := Rect2(x, 0, seg_w, h)
			var col := _seg_color(i)

			if i < active_count:
				# Fully lit
				draw_rect(rect, col, true)
			elif i == active_count and partial > 0.05:
				# Partially lit (fade between ghost and full)
				var blended := Color(col.r, col.g, col.b, 0.12 + partial * 0.88)
				draw_rect(rect, blended, true)
			else:
				# Ghost bar — always visible, dark
				var ghost := Color(col.r * 0.3, col.g * 0.3, col.b * 0.3, 0.15)
				draw_rect(rect, ghost, true)

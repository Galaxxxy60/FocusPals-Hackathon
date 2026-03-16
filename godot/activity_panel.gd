extends CanvasLayer
## Activity Panel — Calendar heatmap + Achievements
## Same retro Y2K style as settings_panel.gd

signal panel_closed()

var _L = preload("res://locale.gd").new()

var is_open := false
var _progress := 0.0
var _panel_container: PanelContainer = null

# Data from Python
var _daily_history: Dictionary = {}
var _streak: int = 0
var _total_sessions: int = 0
var _total_minutes: int = 0
var _achievements: Array = []

# Calendar state
var _cal_year: int = 0
var _cal_month: int = 0  # 1-12

# ── Darker Color Palette for readability ──
const ACT_BG         := Color(0.12, 0.15, 0.22)       # Dark navy background
const ACT_BORDER     := Color(0.30, 0.45, 0.70)       # Blue border
const ACT_ACCENT     := Color(0.40, 0.60, 0.90)       # Bright accent blue
const ACT_DARK       := Color(0.55, 0.65, 0.80)       # Muted text
const ACT_TEXT       := Color(0.90, 0.93, 0.97)       # Near-white text
const ACT_PANEL_BG   := Color(0.16, 0.19, 0.28)       # Card background
const ACT_CARD_BG    := Color(0.20, 0.24, 0.34)       # Slightly lighter card
const ACT_DOT        := Color(0.35, 0.65, 1.0)        # Bright blue dot
const ACT_DOT_DIM    := Color(0.25, 0.40, 0.65)       # Dim dot
const ACT_GOLD       := Color(1.0, 0.85, 0.3)         # Gold for icons
const ACT_TITLE_BG   := Color(0.18, 0.22, 0.32)       # Title bar

const MAX_HEIGHT_RATIO := 0.90

var _quantico_font: Font = null
var _fa_font: FontFile = null

func _ready() -> void:
	layer = 99
	visible = false

func open(data: Dictionary) -> void:
	if is_open:
		return
	is_open = true
	visible = true
	_daily_history = data.get("daily_history", {})
	_streak = int(data.get("streak", 0))
	_total_sessions = int(data.get("total_sessions", 0))
	_total_minutes = int(data.get("total_minutes", 0))
	_achievements = data.get("achievements", [])
	# Set locale from data
	var lang: String = str(data.get("language", "fr"))
	_L.set_lang(lang)
	# Init calendar to current month
	var now := Time.get_datetime_dict_from_system()
	_cal_year = now["year"]
	_cal_month = now["month"]
	_build_ui()
	_progress = 0.0
	var tw := create_tween()
	tw.tween_property(self, "_progress", 1.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func close() -> void:
	if not is_open:
		return
	is_open = false
	var tw := create_tween()
	tw.tween_property(self, "_progress", 0.0, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		visible = false
		_clear_ui()
		panel_closed.emit()
	)

func _clear_ui() -> void:
	if _panel_container:
		_panel_container.queue_free()
		_panel_container = null

func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(ACT_BG.r, ACT_BG.g, ACT_BG.b, 0.97)
	s.border_color = ACT_BORDER
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 8
	return s

func _build_ui() -> void:
	_clear_ui()
	# Load fonts
	if not _quantico_font and ResourceLoader.exists("res://Quantico-Bold.ttf"):
		_quantico_font = load("res://Quantico-Bold.ttf") as Font
	if not _fa_font:
		_fa_font = FontFile.new()
		_fa_font.load_dynamic_font("res://fa-solid-900.ttf")

	var vp := get_viewport().get_visible_rect().size
	var max_h := vp.y * MAX_HEIGHT_RATIO
	var panel_w := 380.0

	_panel_container = PanelContainer.new()
	_panel_container.custom_minimum_size = Vector2(panel_w, 0)
	_panel_container.add_theme_stylebox_override("panel", _make_panel_style())
	_panel_container.position = Vector2(vp.x - panel_w - 20, vp.y * 0.05)
	add_child(_panel_container)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 0)
	_panel_container.add_child(root_vbox)

	# ── Title Bar ──
	var title_panel := PanelContainer.new()
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = ACT_TITLE_BG
	t_style.border_color = ACT_BORDER
	t_style.set_border_width_all(1)
	t_style.content_margin_left = 10
	t_style.content_margin_right = 10
	t_style.content_margin_top = 6
	t_style.content_margin_bottom = 6
	title_panel.add_theme_stylebox_override("panel", t_style)
	root_vbox.add_child(title_panel)

	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 0)
	title_panel.add_child(title_bar)

	# Trophy icon
	var trophy_lbl := Label.new()
	trophy_lbl.text = char(0xF091)  # FA trophy
	trophy_lbl.add_theme_font_override("font", _fa_font)
	trophy_lbl.add_theme_font_size_override("font_size", 18)
	trophy_lbl.add_theme_color_override("font_color", ACT_GOLD)
	title_bar.add_child(trophy_lbl)

	var spacer := Control.new()
	spacer.custom_minimum_size.x = 6
	title_bar.add_child(spacer)

	var title := Label.new()
	title.text = _L.t("activity_title")
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1, 1, 1))
	if _quantico_font:
		title.add_theme_font_override("font", _quantico_font)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(24, 24)
	var close_style := StyleBoxFlat.new()
	close_style.bg_color = Color(0, 0, 0, 0)
	close_btn.add_theme_stylebox_override("normal", close_style)
	close_btn.add_theme_stylebox_override("hover", close_style)
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	close_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	close_btn.pressed.connect(close)
	title_bar.add_child(close_btn)

	# ── Scrollable Content ──
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = min(max_h - 40, 600)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(scroll)

	var scroll_margin := MarginContainer.new()
	scroll_margin.add_theme_constant_override("margin_left", 12)
	scroll_margin.add_theme_constant_override("margin_right", 12)
	scroll_margin.add_theme_constant_override("margin_top", 10)
	scroll_margin.add_theme_constant_override("margin_bottom", 10)
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	scroll_margin.add_child(vbox)

	# ── Stats Cards ──
	_build_stats_row(vbox)

	# ── Calendar ──
	_build_calendar(vbox)

	# ── Achievements ──
	_build_achievements(vbox)

func _build_stats_row(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	_add_stat_card(row, char(0xF06D), "%d" % _streak, _L.t("activity_streak"), Color(1.0, 0.6, 0.2))  # FA fire
	var hours := _total_minutes / 60
	var mins := _total_minutes % 60
	var time_str := "%dh%02d" % [hours, mins] if hours > 0 else "%dmin" % mins
	_add_stat_card(row, char(0xF017), time_str, _L.t("activity_focus"), ACT_ACCENT)  # FA clock
	_add_stat_card(row, char(0xF0E7), "%d" % _total_sessions, _L.t("activity_sessions"), Color(1.0, 0.85, 0.3))  # FA bolt

func _add_stat_card(parent: HBoxContainer, icon_char: String, value: String, label: String, icon_color: Color) -> void:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = ACT_CARD_BG
	card_style.border_color = Color(ACT_BORDER.r, ACT_BORDER.g, ACT_BORDER.b, 0.4)
	card_style.set_border_width_all(1)
	card_style.set_corner_radius_all(5)
	card_style.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", card_style)
	parent.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)

	var icon_lbl := Label.new()
	icon_lbl.text = icon_char
	icon_lbl.add_theme_font_override("font", _fa_font)
	icon_lbl.add_theme_font_size_override("font_size", 18)
	icon_lbl.add_theme_color_override("font_color", icon_color)
	icon_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(icon_lbl)

	var val_lbl := Label.new()
	val_lbl.text = value
	val_lbl.add_theme_font_size_override("font_size", 18)
	val_lbl.add_theme_color_override("font_color", ACT_TEXT)
	if _quantico_font:
		val_lbl.add_theme_font_override("font", _quantico_font)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(val_lbl)

	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", ACT_DARK)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

# ── Calendar ──

func _build_calendar(parent: VBoxContainer) -> void:
	var cal_box := VBoxContainer.new()
	cal_box.add_theme_constant_override("separation", 4)
	parent.add_child(cal_box)

	# Month navigation
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 4)
	cal_box.add_child(nav)

	var prev_btn := Button.new()
	prev_btn.text = char(0xF053)  # FA chevron-left
	prev_btn.add_theme_font_override("font", _fa_font)
	prev_btn.add_theme_font_size_override("font_size", 16)
	prev_btn.add_theme_color_override("font_color", ACT_ACCENT)
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0, 0, 0, 0)
	prev_btn.add_theme_stylebox_override("normal", btn_style)
	prev_btn.add_theme_stylebox_override("hover", btn_style)
	prev_btn.pressed.connect(func():
		_cal_month -= 1
		if _cal_month < 1:
			_cal_month = 12
			_cal_year -= 1
		_rebuild_calendar_grid(cal_box)
	)
	nav.add_child(prev_btn)

	var month_parts := _L.t("activity_months").split("|")
	var month_names: Array[String] = [""]
	month_names.append_array(month_parts)
	var month_lbl := Label.new()
	month_lbl.name = "MonthLabel"
	month_lbl.text = "%s %d" % [month_names[_cal_month], _cal_year]
	month_lbl.add_theme_font_size_override("font_size", 16)
	month_lbl.add_theme_color_override("font_color", ACT_TEXT)
	if _quantico_font:
		month_lbl.add_theme_font_override("font", _quantico_font)
	month_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	month_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(month_lbl)

	var next_btn := Button.new()
	next_btn.text = char(0xF054)  # FA chevron-right
	next_btn.add_theme_font_override("font", _fa_font)
	next_btn.add_theme_font_size_override("font_size", 16)
	next_btn.add_theme_color_override("font_color", ACT_ACCENT)
	next_btn.add_theme_stylebox_override("normal", btn_style)
	next_btn.add_theme_stylebox_override("hover", btn_style)
	next_btn.pressed.connect(func():
		_cal_month += 1
		if _cal_month > 12:
			_cal_month = 1
			_cal_year += 1
		_rebuild_calendar_grid(cal_box)
	)
	nav.add_child(next_btn)

	# Day headers
	var day_row := GridContainer.new()
	day_row.columns = 7
	cal_box.add_child(day_row)
	var day_names := _L.t("activity_days").split("|")
	for dn in day_names:
		var d := Label.new()
		d.text = dn
		d.add_theme_font_size_override("font_size", 12)
		d.add_theme_color_override("font_color", ACT_DARK)
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		d.custom_minimum_size.x = 44
		day_row.add_child(d)

	# Grid
	var grid := GridContainer.new()
	grid.name = "CalGrid"
	grid.columns = 7
	cal_box.add_child(grid)
	_fill_calendar_grid(grid)

func _rebuild_calendar_grid(cal_box: VBoxContainer) -> void:
	# Update month label
	var month_parts := _L.t("activity_months").split("|")
	var month_names: Array[String] = [""]
	month_names.append_array(month_parts)
	var month_lbl: Label = cal_box.find_child("MonthLabel", true, false) as Label
	if month_lbl:
		month_lbl.text = "%s %d" % [month_names[_cal_month], _cal_year]
	# Rebuild grid
	var grid: GridContainer = cal_box.find_child("CalGrid", true, false) as GridContainer
	if grid:
		for c in grid.get_children():
			c.queue_free()
		# Wait a frame for nodes to be freed
		await get_tree().process_frame
		_fill_calendar_grid(grid)

func _fill_calendar_grid(grid: GridContainer) -> void:
	# First day of month (0=Mon in Godot-style, but we compute from OS)
	# Use Time to build date info
	var first_weekday := _weekday_of(_cal_year, _cal_month, 1)  # 0=Mon, 6=Sun
	var days_in_month := _days_in_month(_cal_year, _cal_month)
	var today_dict := Time.get_datetime_dict_from_system()
	var today_str := "%04d-%02d-%02d" % [today_dict["year"], today_dict["month"], today_dict["day"]]

	# Blank cells before first day
	for _i in range(first_weekday):
		var blank := Control.new()
		blank.custom_minimum_size = Vector2(44, 44)
		grid.add_child(blank)

	for day in range(1, days_in_month + 1):
		var date_str := "%04d-%02d-%02d" % [_cal_year, _cal_month, day]
		var minutes := 0
		if _daily_history.has(date_str):
			var day_data = _daily_history[date_str]
			if day_data is Dictionary:
				minutes = int(day_data.get("minutes", 0))

		var cell := Control.new()
		cell.custom_minimum_size = Vector2(44, 44)
		grid.add_child(cell)

		# Day number
		var num := Label.new()
		num.text = str(day)
		num.add_theme_font_size_override("font_size", 11)
		var is_today := date_str == today_str
		if is_today:
			num.add_theme_color_override("font_color", ACT_GOLD)
		else:
			num.add_theme_color_override("font_color", Color(ACT_DARK.r, ACT_DARK.g, ACT_DARK.b, 0.7))
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.set_anchors_preset(Control.PRESET_TOP_WIDE)
		cell.add_child(num)

		# Activity dot — size based on minutes
		if minutes > 0:
			var dot := ColorRect.new()
			var dot_size := clampf(remap(float(minutes), 0.0, 240.0, 8.0, 22.0), 8.0, 22.0)
			dot.custom_minimum_size = Vector2(dot_size, dot_size)
			dot.size = Vector2(dot_size, dot_size)
			# Color intensity based on minutes — bright blue on dark bg
			var intensity := clampf(float(minutes) / 240.0, 0.3, 1.0)
			dot.color = Color(ACT_DOT.r, ACT_DOT.g, ACT_DOT.b, intensity)
			dot.position = Vector2((44 - dot_size) / 2, 20 + (24 - dot_size) / 2)
			cell.add_child(dot)

# ── Achievements ──

func _build_achievements(parent: VBoxContainer) -> void:
	# Section header
	var header := Label.new()
	var unlocked := 0
	for a in _achievements:
		if a is Dictionary and a.get("unlocked", false):
			unlocked += 1
	header.text = "%s  %s  %d/%d" % [char(0xF091), _L.t("activity_achievements"), unlocked, _achievements.size()]
	header.add_theme_font_size_override("font_size", 15)
	header.add_theme_color_override("font_color", ACT_TEXT)
	if _quantico_font:
		header.add_theme_font_override("font", _quantico_font)
	parent.add_child(header)

	for ach in _achievements:
		if not (ach is Dictionary):
			continue
		_build_achievement_card(parent, ach)

func _build_achievement_card(parent: VBoxContainer, ach: Dictionary) -> void:
	var is_unlocked: bool = ach.get("unlocked", false)
	var card := PanelContainer.new()
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(ACT_CARD_BG.r, ACT_CARD_BG.g, ACT_CARD_BG.b, 0.95 if is_unlocked else 0.5)
	card_style.border_color = Color(ACT_BORDER.r, ACT_BORDER.g, ACT_BORDER.b, 0.3)
	card_style.set_border_width_all(1)
	card_style.set_corner_radius_all(5)
	card_style.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", card_style)
	parent.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	# Title row: icon + name
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	vbox.add_child(title_row)

	var icon_lbl := Label.new()
	icon_lbl.text = str(ach.get("icon", "🏆"))
	icon_lbl.add_theme_font_size_override("font_size", 22)
	if not is_unlocked:
		icon_lbl.modulate = Color(0.5, 0.5, 0.5, 0.6)
	title_row.add_child(icon_lbl)

	var name_lbl := Label.new()
	name_lbl.text = str(ach.get("name", "???"))
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", ACT_TEXT if is_unlocked else Color(ACT_DARK.r, ACT_DARK.g, ACT_DARK.b, 0.5))
	if _quantico_font:
		name_lbl.add_theme_font_override("font", _quantico_font)
	title_row.add_child(name_lbl)

	# Description
	var desc_lbl := Label.new()
	desc_lbl.text = str(ach.get("desc", ""))
	desc_lbl.add_theme_font_size_override("font_size", 11)
	desc_lbl.add_theme_color_override("font_color", Color(ACT_DARK.r, ACT_DARK.g, ACT_DARK.b, 0.8))
	vbox.add_child(desc_lbl)

	# Progress bar (only if not unlocked)
	if not is_unlocked:
		var progress_val: int = int(ach.get("progress", 0))
		var req_val: int = int(ach.get("req", 1))
		var pct: float = clampf(float(progress_val) / float(max(req_val, 1)), 0.0, 1.0)

		var bar_bg := ColorRect.new()
		bar_bg.custom_minimum_size = Vector2(0, 8)
		bar_bg.color = Color(ACT_BG.r, ACT_BG.g, ACT_BG.b, 0.7)
		vbox.add_child(bar_bg)

		var bar_fill := ColorRect.new()
		bar_fill.custom_minimum_size = Vector2(0, 8)
		bar_fill.color = Color(ACT_ACCENT.r, ACT_ACCENT.g, ACT_ACCENT.b, 0.8)
		bar_fill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		bar_fill.anchor_right = pct
		bar_bg.add_child(bar_fill)

		var prog_lbl := Label.new()
		prog_lbl.text = "%d / %d" % [progress_val, req_val]
		prog_lbl.add_theme_font_size_override("font_size", 10)
		prog_lbl.add_theme_color_override("font_color", Color(ACT_DARK.r, ACT_DARK.g, ACT_DARK.b, 0.6))
		prog_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		vbox.add_child(prog_lbl)

# ── Date helpers ──

func _weekday_of(year: int, month: int, day: int) -> int:
	## Returns 0=Mon, 1=Tue, ..., 6=Sun using Tomohiko Sakamoto's algorithm
	var t: Array[int] = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
	var y: int = year
	if month < 3:
		y -= 1
	var w: int = (y + y / 4 - y / 100 + y / 400 + t[month - 1] + day) % 7
	# w: 0=Sun, 1=Mon, ..., 6=Sat → convert to 0=Mon
	return (w + 6) % 7

func _days_in_month(year: int, month: int) -> int:
	if month in [4, 6, 9, 11]:
		return 30
	if month == 2:
		if (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0):
			return 29
		return 28
	return 31

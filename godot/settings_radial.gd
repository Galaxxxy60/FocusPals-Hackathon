extends CanvasLayer
## Radial semicircular settings menu — Retro Pixel Art Y2K Style
## Clicks are required. Uses a 1% opacity background to capture clicks securely
## and prevents them from passing through to desktop windows.

signal action_triggered(action_id: String)
signal request_hide()

var _L = preload("res://locale.gd").new()

# ── Retro Color Palette ──
const RETRO_BG       := Color(0.906, 0.933, 0.965)  # #e7eef6 — centre
const RETRO_BORDER   := Color(0.502, 0.682, 0.890)  # #80aee3 — contour
const RETRO_SURCONTOUR := Color(0.553, 0.737, 0.918)  # #8dbcea — sur-contour
const RETRO_ACCENT   := Color(0.659, 0.784, 0.941)  # #a8c8f0
const RETRO_DARK     := Color(0.345, 0.537, 0.769)  # #5889c4
const RETRO_TEXT     := Color(0.227, 0.353, 0.541)  # #3a5a8a
const RETRO_PANEL_BG := Color(0.863, 0.910, 0.957)  # #dce8f4
const RETRO_HOVER    := Color(0.710, 0.816, 0.941)  # #b5d0f0
const RETRO_GRID     := Color(0.502, 0.682, 0.890, 0.12)  # Grid lines

var ITEMS := [
	{"icon": "cog", "label": "Settings",      "id": "settings", "color": RETRO_BORDER,  "scale": 1.0, "loc_key": "radial_settings"},
	{"icon": "tama", "label": "Appeler Tama",   "id": "call_tama",  "color": RETRO_DARK,  "scale": 1.5, "loc_key": "radial_call_tama"},
	{"icon": "quit", "label": "Quit",           "id": "quit",     "color": Color(0.878, 0.533, 0.533),  "scale": 1.0, "loc_key": "radial_quit"},
]

const ARC_RADIUS := 110.0
const ITEM_SIZE  := 32.0
const ARC_SPREAD := 2.4

var is_open := false
var tama_active := false  # Set by main.gd — greys out 'call_tama' when Tama is on screen
var _progress := 0.0
var _hovered := -1
var _hover_scales: Array[float] = []
var _canvas: Control
var _close_timer := 0.0
var _first_open := true  # True on first launch — stays open until user hovers an item

var _label_alpha := 0.0
var _label_text := ""
var _label_color := Color.WHITE

var _fa_font: FontFile
var _tama_tex: Texture2D

func _ready() -> void:
	layer = 100
	visible = false
	_fa_font = FontFile.new()
	_fa_font.load_dynamic_font("res://fa-solid-900.ttf")
	_tama_tex = preload("res://Tama_icon.png")
	for i in ITEMS.size():
		_hover_scales.append(0.0)
	_canvas = Control.new()
	_canvas.name = "RadialCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	# STOP filters clicks so they are processed by _on_input and not passed further
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.connect("draw", _draw_menu)
	_canvas.connect("gui_input", _on_input)
	add_child(_canvas)

func _arc_center() -> Vector2:
	# Anchor to the right edge of our parent window (works wherever Tama is)
	var parent_win := get_window()
	var win_size := parent_win.size if parent_win else Vector2i(400, 500)
	# Right edge of window, 70% down
	return Vector2(float(win_size.x), float(win_size.y) * 0.7)

func _item_pos(index: int) -> Vector2:
	var n := ITEMS.size()
	var half := ARC_SPREAD / 2.0
	var step: float = ARC_SPREAD / maxf(n - 1, 1)
	var angle := -half + step * index
	var center := _arc_center()
	# Push call_tama further out so the label doesn't overlap
	var extra := 30.0 if ITEMS[index]["id"] == "call_tama" else 0.0
	var r := (ARC_RADIUS + extra) * _progress
	return center + Vector2(-r * cos(angle), r * sin(angle))

func set_lang(lang_code: String) -> void:
	_L.set_lang(lang_code)
	for item in ITEMS:
		if item.has("loc_key"):
			item["label"] = _L.t(item["loc_key"])

func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	_close_timer = 0.0
	_hovered = -1
	# Update labels to current language
	for item in ITEMS:
		if item.has("loc_key"):
			item["label"] = _L.t(item["loc_key"])
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)
	var tw := create_tween()
	tw.tween_property(self, "_progress", 1.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func close() -> void:
	if not is_open:
		return
	is_open = false
	var tw := create_tween()
	tw.tween_property(self, "_progress", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_on_closed)

func _on_closed() -> void:
	visible = false
	request_hide.emit()

func _process(delta: float) -> void:
	if not visible:
		return
	for i in _hover_scales.size():
		var target := 1.0 if i == _hovered else 0.0
		_hover_scales[i] = lerp(_hover_scales[i], target, delta * 12.0)
	_update_hover(delta)
	_canvas.queue_redraw()

func _update_hover(delta: float) -> void:
	var mouse := _canvas.get_local_mouse_position()
	_hovered = -1
	if _progress < 0.5:
		return
	for i in ITEMS.size():
		# Skip disabled items for hover
		if ITEMS[i]["id"] == "call_tama" and tama_active:
			continue
		if mouse.distance_to(_item_pos(i)) < ITEM_SIZE * 1.8:
			_hovered = i
			# First hover clears the "sticky" first-open mode
			if _first_open:
				_first_open = false
			break
	# Don't auto-close on first open — wait for user to discover the menu
	if _first_open:
		return
	if is_open and _progress >= 0.5:
		var center := _arc_center()
		var dist := mouse.distance_to(center)
		var threshold := ARC_RADIUS + ITEM_SIZE * 2.5
		if dist > threshold * 1.8:
			close()
		elif dist > threshold:
			_close_timer += delta * 3.0
			if _close_timer > 0.3:
				close()
		else:
			_close_timer = 0.0

func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _hovered >= 0:
			var item: Dictionary = ITEMS[_hovered]
			action_triggered.emit(item["id"])
			close()
		else:
			close()

func _draw_menu() -> void:
	if _progress < 0.01:
		return
		
	# Block OS click-through by making the window technically not 100% transparent
	_canvas.draw_rect(Rect2(0, 0, _canvas.size.x, _canvas.size.y), Color(0, 0, 0, 0.01))
	
	var center := _arc_center()
	var alpha := _progress
	
	# ── Retro Grid Pattern (subtle background grid) ──
	_draw_retro_grid(center, alpha)
	
	# ── Retro Arc Rings (double-border Y2K style) ──
	# Sur-contour ring (outer glow)
	var outer_r := (ARC_RADIUS + 50) * _progress
	_draw_pixel_arc(center, outer_r, 3.0 * _progress, Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, 0.25 * alpha))
	# Main contour ring
	var main_r := (ARC_RADIUS + 38) * _progress
	_draw_pixel_arc(center, main_r, 2.0 * _progress, Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.4 * alpha))
	# Inner ring
	var inner_r := (ARC_RADIUS - 10) * _progress
	_draw_pixel_arc(center, inner_r, 1.5 * _progress, Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.15 * alpha))
	
	# ── Retro Connection Lines (dashed/pixel style) ──
	for i in ITEMS.size():
		_draw_pixel_line(center, _item_pos(i), Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.3 * alpha), 2.0)
	
	# ── Draw Items ──
	for i in ITEMS.size():
		_draw_item(i)
	
	# ── Center Label ──
	_draw_center_label(center, alpha)
	
	# ── Center Dot (retro style) ──
	var dot_a := 0.9 * alpha * (1.0 - _label_alpha * 0.7)
	# Double border dot (retro style)
	_canvas.draw_circle(center, 8 * _progress, Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, dot_a * 0.5))
	_canvas.draw_circle(center, 6 * _progress, Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, dot_a))
	_canvas.draw_circle(center, 4 * _progress, Color(RETRO_BG.r, RETRO_BG.g, RETRO_BG.b, dot_a))

func _draw_retro_grid(center: Vector2, alpha: float) -> void:
	"""Draw a subtle retro grid pattern around the arc area."""
	var grid_size := 16.0
	var grid_radius := (ARC_RADIUS + 80) * _progress
	var grid_col := Color(RETRO_GRID.r, RETRO_GRID.g, RETRO_GRID.b, RETRO_GRID.a * alpha * 0.5)
	
	var start_x := center.x - grid_radius
	var end_x := center.x + 20
	var start_y := center.y - grid_radius
	var end_y := center.y + grid_radius
	
	# Vertical lines
	var x := start_x
	while x <= end_x:
		var dist_from_center := center.distance_to(Vector2(x, center.y))
		if dist_from_center < grid_radius:
			var fade = 1.0 - (dist_from_center / grid_radius)
			_canvas.draw_line(
				Vector2(x, maxf(start_y, center.y - sqrt(maxf(grid_radius * grid_radius - (x - center.x) * (x - center.x), 0)))),
				Vector2(x, minf(end_y, center.y + sqrt(maxf(grid_radius * grid_radius - (x - center.x) * (x - center.x), 0)))),
				Color(grid_col.r, grid_col.g, grid_col.b, grid_col.a * fade),
				1.0
			)
		x += grid_size
	
	# Horizontal lines
	var y := start_y
	while y <= end_y:
		var dist_from_center := center.distance_to(Vector2(center.x, y))
		if dist_from_center < grid_radius:
			var fade = 1.0 - (dist_from_center / grid_radius)
			_canvas.draw_line(
				Vector2(maxf(start_x, center.x - sqrt(maxf(grid_radius * grid_radius - (y - center.y) * (y - center.y), 0))), y),
				Vector2(minf(end_x, center.x + sqrt(maxf(grid_radius * grid_radius - (y - center.y) * (y - center.y), 0))), y),
				Color(grid_col.r, grid_col.g, grid_col.b, grid_col.a * fade),
				1.0
			)
		y += grid_size

func _draw_pixel_arc(center: Vector2, radius: float, width: float, color: Color) -> void:
	"""Draw a pixelated arc (stepped segments for retro feel)."""
	var segs := 24
	var half := ARC_SPREAD / 2.0
	for j in segs:
		var a1 := -half + (ARC_SPREAD / segs) * j
		var a2 := -half + (ARC_SPREAD / segs) * (j + 1)
		var p1 := center + Vector2(-radius * cos(a1), radius * sin(a1))
		var p2 := center + Vector2(-radius * cos(a2), radius * sin(a2))
		# Snap to pixel grid for retro feel
		p1 = Vector2(roundf(p1.x), roundf(p1.y))
		p2 = Vector2(roundf(p2.x), roundf(p2.y))
		_canvas.draw_line(p1, p2, color, width)

func _draw_pixel_line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	"""Draw a line snapped to pixel grid."""
	var f := Vector2(roundf(from.x), roundf(from.y))
	var t := Vector2(roundf(to.x), roundf(to.y))
	_canvas.draw_line(f, t, color, width)

func _draw_center_label(center: Vector2, alpha: float) -> void:
	if _hovered >= 0:
		_label_text = ITEMS[_hovered]["label"]
		_label_color = ITEMS[_hovered]["color"]
		_label_alpha = minf(_label_alpha + 0.15, 1.0)
	else:
		_label_alpha = maxf(_label_alpha - 0.12, 0.0)
	if _label_alpha < 0.01:
		return
	var font := ThemeDB.fallback_font
	var ts := font.get_string_size(_label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
	var lpos := center + Vector2(-ARC_RADIUS * 0.5 * _progress, 0)
	var pw := ts.x + 20.0
	var ph := ts.y + 14.0
	var pill := Rect2(lpos.x - pw / 2, lpos.y - ph / 2, pw, ph)
	
	# Retro window-style label (double border like Windows 98)
	# Sur-contour (outer)
	var outer_pill := Rect2(pill.position.x - 2, pill.position.y - 2, pill.size.x + 4, pill.size.y + 4)
	_canvas.draw_rect(outer_pill, Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, 0.5 * _label_alpha * alpha), false, 1.5)
	# Main border
	_canvas.draw_rect(pill, Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.7 * _label_alpha * alpha), false, 2.0)
	# Background fill
	_canvas.draw_rect(pill, Color(RETRO_BG.r, RETRO_BG.g, RETRO_BG.b, 0.92 * _label_alpha * alpha), true)
	# Text (dark on light bg — retro style)
	_canvas.draw_string(font, Vector2(lpos.x - ts.x / 2, lpos.y + ts.y * 0.3),
		_label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(RETRO_TEXT.r, RETRO_TEXT.g, RETRO_TEXT.b, _label_alpha * alpha))

func _draw_item(index: int) -> void:
	var item: Dictionary = ITEMS[index]
	var pos := _item_pos(index)
	var hover: float = _hover_scales[index]
	var alpha := _progress
	var item_scale := 1.0
	if item.has("scale"):
		item_scale = float(item["scale"])
	var r := ITEM_SIZE * item_scale * (1.0 + hover * 0.2)
	var accent: Color = item["color"]
	# Grey out disabled items
	var is_disabled = (item["id"] == "call_tama" and tama_active)
	if is_disabled:
		accent = Color(0.6, 0.6, 0.65)
		alpha *= 0.3
	
	# ── Retro Circle Drawing (triple-ring pixel art style) ──
	
	# Hover glow (retro scanline-like rings)
	if hover > 0.01:
		for g in range(3):
			var gr := r + (6 + g * 5) * hover
			var ga := 0.10 * hover * (3.0 - g) / 3.0
			_canvas.draw_circle(pos, gr, Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, ga))
	
	# Sur-contour ring (outer)   #8dbcea
	_canvas.draw_circle(pos, r + 6, Color(RETRO_SURCONTOUR.r, RETRO_SURCONTOUR.g, RETRO_SURCONTOUR.b, 0.6 * alpha))
	# Main contour ring          #80aee3
	_canvas.draw_circle(pos, r + 4, Color(RETRO_BORDER.r, RETRO_BORDER.g, RETRO_BORDER.b, 0.85 * alpha))
	# Center fill                #e7eef6
	_canvas.draw_circle(pos, r, Color(RETRO_BG.r, RETRO_BG.g, RETRO_BG.b, 0.95 * alpha))
	
	# Inner accent ring (subtle, for depth)
	_canvas.draw_circle(pos, r - 3, Color(RETRO_PANEL_BG.r, RETRO_PANEL_BG.g, RETRO_PANEL_BG.b, 0.3 * alpha))
	
	# Draw Icon
	var icon_id: String = item["icon"]
	if icon_id == "tama":
		var tex_size := 32.0 * item_scale * (1.0 + hover * 0.2)
		var rect := Rect2(pos.x - tex_size / 2, pos.y - tex_size / 2, tex_size, tex_size)
		_canvas.draw_texture_rect(_tama_tex, rect, false, Color(1, 1, 1, alpha))
	else:
		var icon_str := ""
		var tint := Color(RETRO_TEXT.r, RETRO_TEXT.g, RETRO_TEXT.b, alpha)
		if icon_id == "cog":
			icon_str = char(0xF013)
		elif icon_id == "quit":
			icon_str = char(0xF011)
			var danger := Color(0.878, 0.533, 0.533)
			tint = Color(danger.r, danger.g, danger.b, alpha)
			
		var fs := int((20 + hover * 4) * item_scale)
		if _fa_font:
			var ts := _fa_font.get_string_size(icon_str, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
			_canvas.draw_string(_fa_font, pos + Vector2(-ts.x / 2, ts.y * 0.35),
				icon_str, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, tint)

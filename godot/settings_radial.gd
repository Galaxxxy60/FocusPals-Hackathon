extends CanvasLayer
## Radial semicircular settings menu
## Clicks are required. Uses a 1% opacity background to capture clicks securely
## and prevent them from passing through to desktop windows.

signal action_triggered(action_id: String)
signal request_hide()

var ITEMS := [
	{"icon": "⚙️", "label": "Settings",  "id": "settings", "color": Color(0.4, 0.8, 1.0),  "scale": 0.85},
	{"icon": "💬", "label": "Parler",   "id": "talk",     "color": Color(0.6, 0.4, 1.0),  "scale": 1.0},
	{"icon": "⚡", "label": "Session",  "id": "session",  "color": Color(0.4, 1.0, 0.5),  "scale": 1.35},
	{"icon": "🎯", "label": "Tâche",    "id": "task",     "color": Color(1.0, 0.85, 0.3), "scale": 0.9},
	{"icon": "⏰", "label": "Pauses",   "id": "breaks",   "color": Color(1.0, 0.5, 0.8),  "scale": 0.9},
	{"icon": "⛔", "label": "Quitter",  "id": "quit",     "color": Color(1.0, 0.3, 0.3),  "scale": 0.85},
]

const ARC_RADIUS := 120.0
const ITEM_SIZE  := 28.0
const ARC_SPREAD := 2.4

var is_open := false
var _progress := 0.0
var _hovered := -1
var _hover_scales: Array[float] = []
var _canvas: Control
var _close_timer := 0.0

var _label_alpha := 0.0
var _label_text := ""
var _label_color := Color.WHITE

func _ready() -> void:
	layer = 100
	visible = false
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
	var vp := get_viewport().get_visible_rect().size
	return Vector2(vp.x, vp.y * 0.7)

func _item_pos(index: int) -> Vector2:
	var n := ITEMS.size()
	var half := ARC_SPREAD / 2.0
	var step: float = ARC_SPREAD / maxf(n - 1, 1)
	var angle := -half + step * index
	var center := _arc_center()
	var r := ARC_RADIUS * _progress
	return center + Vector2(-r * cos(angle), r * sin(angle))

func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	_close_timer = 0.0
	_hovered = -1
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
		if mouse.distance_to(_item_pos(i)) < ITEM_SIZE * 1.6:
			_hovered = i
			break
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
	for ring in range(4):
		var rr := (ARC_RADIUS + 40 - ring * 12) * _progress
		var col := Color(0.25, 0.55, 1.0, 0.03 * alpha * (4 - ring))
		_draw_arc_segments(center, rr, 8.0 * _progress, col)
	for i in ITEMS.size():
		_canvas.draw_line(center, _item_pos(i), Color(0.35, 0.55, 0.85, 0.25 * alpha), 1.5)
	for i in ITEMS.size():
		_draw_item(i)
	_draw_center_label(center, alpha)
	var dot_a := 0.85 * alpha * (1.0 - _label_alpha * 0.7)
	_canvas.draw_circle(center, 5 * _progress, Color(0.45, 0.7, 1.0, dot_a))

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
	var ts := font.get_string_size(_label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 16)
	var lpos := center + Vector2(-ARC_RADIUS * 0.5 * _progress, 0)
	var pw := ts.x + 18.0
	var ph := ts.y + 12.0
	var pill := Rect2(lpos.x - pw / 2, lpos.y - ph / 2, pw, ph)
	_canvas.draw_rect(pill, Color(0.05, 0.05, 0.1, 0.85 * _label_alpha * alpha), true)
	_canvas.draw_rect(pill, Color(_label_color.r, _label_color.g, _label_color.b, 0.5 * _label_alpha * alpha), false, 1.5)
	_canvas.draw_string(font, Vector2(lpos.x - ts.x / 2, lpos.y + ts.y * 0.3),
		_label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, _label_alpha * alpha))

func _draw_arc_segments(center: Vector2, radius: float, width: float, color: Color) -> void:
	var segs := 24
	var half := ARC_SPREAD / 2.0
	for j in segs:
		var a1 := -half + (ARC_SPREAD / segs) * j
		var a2 := -half + (ARC_SPREAD / segs) * (j + 1)
		var p1 := center + Vector2(-radius * cos(a1), radius * sin(a1))
		var p2 := center + Vector2(-radius * cos(a2), radius * sin(a2))
		_canvas.draw_line(p1, p2, color, width)

func _draw_item(index: int) -> void:
	var item: Dictionary = ITEMS[index]
	var pos := _item_pos(index)
	var hover: float = _hover_scales[index]
	var alpha := _progress
	var item_scale := 1.0
	if item.has("scale"):
		item_scale = float(item["scale"])
	var r := ITEM_SIZE * item_scale * (1.0 + hover * 0.25)
	var accent: Color = item["color"]
	
	if hover > 0.01:
		for g in range(3):
			var gr := r + (5 + g * 4) * hover
			var ga := 0.12 * hover * (3.0 - g) / 3.0
			_canvas.draw_circle(pos, gr, Color(accent.r, accent.g, accent.b, ga))
	_canvas.draw_circle(pos, r + 2, Color(accent.r, accent.g, accent.b, 0.6 * alpha))
	_canvas.draw_circle(pos, r, Color(0.07, 0.07, 0.13, 0.92 * alpha))
	var font := ThemeDB.fallback_font
	var fs := int((18 + hover * 4) * item_scale)
	var icon_str: String = item["icon"]
	var ts := font.get_string_size(icon_str, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	_canvas.draw_string(font, pos + Vector2(-ts.x / 2, ts.y * 0.3),
		icon_str, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(1, 1, 1, alpha))

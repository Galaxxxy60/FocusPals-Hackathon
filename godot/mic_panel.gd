extends CanvasLayer
## Microphone selection panel — uses _input() directly for 100% reliable click capture.
## Positioned at the center of the radial menu arc.

signal mic_selected(mic_index: int)
signal panel_closed()

var is_open := false
var _progress := 0.0
var _mics: Array = []
var _selected_index: int = -1
var _hovered: int = -1
var _canvas: Control

const PANEL_WIDTH := 280.0
const ITEM_HEIGHT := 36.0
const PADDING := 12.0
const MARGIN_RIGHT := 10.0

func _ready() -> void:
	layer = 101
	visible = false
	_canvas = Control.new()
	_canvas.name = "MicCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.connect("draw", _draw_panel)
	add_child(_canvas)

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
	var tw := create_tween()
	tw.tween_property(self, "_progress", 1.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func close() -> void:
	if not is_open:
		return
	is_open = false
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
	return Rect2(pr.position.x + PADDING, y, PANEL_WIDTH - PADDING * 2, ITEM_HEIGHT - 4)

func _process(_delta: float) -> void:
	if not visible:
		return
	_update_hover()
	_canvas.queue_redraw()

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

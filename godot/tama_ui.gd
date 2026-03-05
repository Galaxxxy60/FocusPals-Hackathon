extends Node
## Tama UI — Status indicator + Session progress arc
##
## Manages overlay UI elements that are independent of character behavior.
## Call from main:
##   setup(parent)                     — once in _ready
##   update(delta)                     — every frame from _process
##   show_status(text, color)          — show status text
##   hide_status()                     — hide status text
##   redraw_arc()                      — trigger arc redraw when session is active

# ─── State ───────────────────────────────────────────────
var _status_label: Label
var _status_canvas: CanvasLayer
var _status_visible: bool = false
var _status_dots: int = 0
var _status_timer: float = 0.0

var _arc_canvas: CanvasLayer
var _arc_control: Control

# These are read from the main script via the parent reference
var _parent: Node = null

# ─── Public API ──────────────────────────────────────────

func setup(parent: Node) -> void:
	_parent = parent
	_setup_status_indicator()
	_setup_arc()

func update(delta: float) -> void:
	_update_status_indicator(delta)
	# Session progress arc redraw
	if _arc_control and _parent and _parent.session_active:
		_arc_control.queue_redraw()

func show_status(text: String, color: Color) -> void:
	_status_visible = true
	_status_label.visible = true
	_status_dots = 0
	_status_timer = 0.0
	_status_label.text = text + "..."
	_status_label.add_theme_color_override("font_color", color)

func hide_status() -> void:
	_status_visible = false
	_status_label.visible = false

# ─── Status Indicator ────────────────────────────────────

func _setup_status_indicator() -> void:
	_status_canvas = CanvasLayer.new()
	_status_canvas.layer = 10
	_parent.add_child(_status_canvas)
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0, 0.9))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_top = -40
	_status_label.offset_bottom = -10
	_status_canvas.add_child(_status_label)
	_status_label.visible = false

func _update_status_indicator(delta: float) -> void:
	if not _status_visible:
		return
	_status_timer += delta
	if _status_timer >= 0.5:
		_status_timer = 0.0
		_status_dots = (_status_dots + 1) % 4
		var dots = ".".repeat(_status_dots + 1)
		# Extract base text (before dots)
		var base_text = _status_label.text
		var dot_start = base_text.find(".")
		if dot_start > 0:
			base_text = base_text.substr(0, dot_start)
		_status_label.text = base_text + dots
	# Pulse alpha — gentle breathing effect
	var alpha = 0.5 + 0.4 * sin(Time.get_ticks_msec() * 0.004)
	_status_label.modulate = Color(1, 1, 1, alpha)

# ─── Session Progress Arc ────────────────────────────────

func _setup_arc() -> void:
	_arc_canvas = CanvasLayer.new()
	_arc_canvas.layer = 50  # Behind menus (100+), above 3D
	_parent.add_child(_arc_canvas)
	_arc_control = Control.new()
	_arc_control.name = "SessionArc"
	_arc_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arc_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arc_control.connect("draw", _draw_session_arc)
	_arc_canvas.add_child(_arc_control)

func _draw_session_arc() -> void:
	if _parent == null or not _parent.session_active or _parent.session_duration_secs <= 0:
		return

	var vp := _parent.get_viewport().get_visible_rect().size
	# Same center as radial menu (right edge, 70% down)
	var center := Vector2(vp.x, vp.y * 0.7)
	var radius := 36.0
	var thickness := 4.0
	var progress := clampf(float(_parent.session_elapsed_secs) / float(_parent.session_duration_secs), 0.0, 1.0)

	# Semicircle opening LEFT: from bottom to top
	var segments := 48
	var start_angle := PI * 0.5
	var end_angle := PI * 1.5
	var arc_span := end_angle - start_angle

	# Track (dark, subtle)
	for i in range(segments):
		var a1 := start_angle + arc_span * (float(i) / float(segments))
		var a2 := start_angle + arc_span * (float(i + 1) / float(segments))
		var p1 := center + Vector2(cos(a1), sin(a1)) * radius
		var p2 := center + Vector2(cos(a2), sin(a2)) * radius
		_arc_control.draw_line(p1, p2, Color(0.15, 0.2, 0.3, 0.4), thickness, true)

	# Fill (bright, based on progress)
	if progress > 0.005:
		var fill_segments := int(segments * progress)
		var fill_color := Color(0.3, 0.7, 1.0, 0.85)
		if progress > 0.9:
			fill_color = Color(0.3, 1.0, 0.5, 0.9)
		elif progress > 0.75:
			fill_color = Color(0.4, 0.85, 0.6, 0.85)
		for i in range(fill_segments):
			var a1 := start_angle + arc_span * (float(i) / float(segments))
			var a2 := start_angle + arc_span * (float(i + 1) / float(segments))
			var p1 := center + Vector2(cos(a1), sin(a1)) * radius
			var p2 := center + Vector2(cos(a2), sin(a2)) * radius
			_arc_control.draw_line(p1, p2, fill_color, thickness + 1.5, true)

		# Glow dot at tip
		var tip_angle := start_angle + arc_span * progress
		var tip := center + Vector2(cos(tip_angle), sin(tip_angle)) * radius
		_arc_control.draw_circle(tip, 3.5, fill_color)
		_arc_control.draw_circle(tip, 6.0, Color(fill_color.r, fill_color.g, fill_color.b, 0.25))

	# Time remaining text
	var remaining := maxi(_parent.session_duration_secs - _parent.session_elapsed_secs, 0)
	var mins := remaining / 60
	var secs := remaining % 60
	var time_str := "%d:%02d" % [mins, secs]
	var font := ThemeDB.fallback_font
	var ts := font.get_string_size(time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 10)
	_arc_control.draw_string(font,
		Vector2(center.x - radius - ts.x - 6, center.y + ts.y * 0.3),
		time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 10,
		Color(0.6, 0.75, 0.9, 0.7))

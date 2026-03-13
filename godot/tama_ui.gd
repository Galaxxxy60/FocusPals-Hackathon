extends Node
## Tama UI — Status indicator + Session progress arc + Break overlay
##
## Manages overlay UI elements that are independent of character behavior.
## Call from main:
##   setup(parent, render_target)        — once in _ready (render_target = _tama_window)
##   update(delta)                       — every frame from _process
##   show_status(text, color)            — show status text
##   hide_status()                       — hide status text
##   show_break_overlay(break_dur_min)   — show break countdown overlay
##   hide_break_overlay()                — hide break overlay
##   redraw_arc()                        — trigger arc redraw when session is active

# ─── State ───────────────────────────────────────────────
var _status_label: Label
var _status_canvas: CanvasLayer
var _status_visible: bool = false
var _status_dots: int = 0
var _status_timer: float = 0.0

var _arc_canvas: CanvasLayer
var _arc_control: Control

# Break overlay
var _break_canvas: CanvasLayer
var _break_control: Control
var _break_visible: bool = false
var _break_start_time: float = 0.0
var _break_duration_secs: float = 300.0  # 5 min default

# These are read from the main script via the parent reference
var _parent: Node = null
var _render_target: Node = null  # Where to attach CanvasLayers (usually _tama_window)

# ─── Public API ──────────────────────────────────────────

func setup(parent: Node, render_target: Node = null) -> void:
	_parent = parent
	# If no render_target specified, fall back to parent
	# (render_target should be _tama_window so overlays appear on Tama's window)
	_render_target = render_target if render_target else parent
	_setup_status_indicator()
	_setup_arc()
	_setup_break_overlay()

func update(delta: float) -> void:
	_update_status_indicator(delta)
	# Session progress arc redraw
	if _arc_control and _parent and _parent.session_active:
		_arc_control.queue_redraw()
	# Also redraw if arc was visible but session ended (to clear it)
	elif _arc_control and _parent and not _parent.session_active:
		_arc_control.queue_redraw()
	# Break overlay redraw
	if _break_visible and _break_control:
		_break_control.queue_redraw()

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

func show_break_overlay(break_duration_min: float) -> void:
	_break_visible = true
	_break_start_time = Time.get_unix_time_from_system()
	_break_duration_secs = break_duration_min * 60.0
	if _break_control:
		_break_control.visible = true
		_break_control.queue_redraw()
	print("☕ Break overlay shown: %.0f min" % break_duration_min)

func hide_break_overlay() -> void:
	_break_visible = false
	if _break_control:
		_break_control.visible = false
	print("☕ Break overlay hidden")

# ─── Status Indicator ────────────────────────────────────

func _setup_status_indicator() -> void:
	_status_canvas = CanvasLayer.new()
	_status_canvas.layer = 10
	_render_target.add_child(_status_canvas)
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
	_render_target.add_child(_arc_canvas)
	_arc_control = Control.new()
	_arc_control.name = "SessionArc"
	_arc_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arc_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arc_control.connect("draw", _draw_session_arc)
	_arc_canvas.add_child(_arc_control)

func _draw_session_arc() -> void:
	if _parent == null or not _parent.session_active or _parent.session_duration_secs <= 0:
		return

	# Use _render_target's viewport size (the tama_window)
	var vp_size: Vector2
	if _render_target and _render_target is Window:
		vp_size = Vector2(_render_target.size)
	elif _parent:
		vp_size = _parent.get_viewport().get_visible_rect().size
	else:
		return

	# Arc on the right edge, 70% down (same reference as radial menu)
	var center := Vector2(vp_size.x, vp_size.y * 0.7)
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

# ─── Break Overlay ───────────────────────────────────────

func _setup_break_overlay() -> void:
	_break_canvas = CanvasLayer.new()
	_break_canvas.layer = 55  # Above session arc (50), below menus (100+)
	_render_target.add_child(_break_canvas)
	_break_control = Control.new()
	_break_control.name = "BreakOverlay"
	_break_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_break_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_break_control.connect("draw", _draw_break_overlay)
	_break_canvas.add_child(_break_control)
	_break_control.visible = false

func _draw_break_overlay() -> void:
	if not _break_visible:
		return

	var vp_size: Vector2
	if _render_target and _render_target is Window:
		vp_size = Vector2(_render_target.size)
	elif _parent:
		vp_size = _parent.get_viewport().get_visible_rect().size
	else:
		return

	var elapsed := Time.get_unix_time_from_system() - _break_start_time
	var remaining := maxf(_break_duration_secs - elapsed, 0.0)
	var progress := clampf(elapsed / _break_duration_secs, 0.0, 1.0)

	# ── Soft background tint ──
	_break_control.draw_rect(
		Rect2(Vector2.ZERO, vp_size),
		Color(0.1, 0.15, 0.25, 0.15)
	)

	# ── Break timer text (centered, large) ──
	var font := ThemeDB.fallback_font
	var mins := int(remaining) / 60
	var secs := int(remaining) % 60
	var time_str := "☕ %d:%02d" % [mins, secs]
	var font_size := 16
	var ts := font.get_string_size(time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	var text_pos := Vector2(vp_size.x * 0.5 - ts.x * 0.5, vp_size.y * 0.15)

	# Glow background behind text
	_break_control.draw_rect(
		Rect2(text_pos.x - 12, text_pos.y - ts.y - 4, ts.x + 24, ts.y + 12),
		Color(0.1, 0.15, 0.25, 0.5),
		true, -1.0, true, 6.0
	)

	# Text color: soft blue → green as break progresses
	var text_color := Color(0.4, 0.7, 1.0, 0.9).lerp(Color(0.3, 1.0, 0.5, 0.9), progress)
	_break_control.draw_string(font, text_pos, time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, text_color)

	# ── Small progress bar ──
	var bar_w := vp_size.x * 0.4
	var bar_h := 3.0
	var bar_x := vp_size.x * 0.5 - bar_w * 0.5
	var bar_y := text_pos.y + 8
	# Track
	_break_control.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.2, 0.25, 0.35, 0.4))
	# Fill
	_break_control.draw_rect(Rect2(bar_x, bar_y, bar_w * progress, bar_h), text_color)

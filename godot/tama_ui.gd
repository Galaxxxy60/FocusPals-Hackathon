extends Node
## Tama UI — Status indicator + Session timer (above head) + Break overlay
##
## Manages overlay UI elements that are independent of character behavior.
## The session timer floats ABOVE Tama's head using the projected head bone position.

# ─── State ───────────────────────────────────────────────
var _status_label: Label
var _status_canvas: CanvasLayer
var _status_visible: bool = false
var _status_dots: int = 0
var _status_timer: float = 0.0

var _session_canvas: CanvasLayer
var _session_control: Control

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
	_render_target = render_target if render_target else parent
	_setup_status_indicator()
	_setup_session_display()
	_setup_break_overlay()

func update(delta: float) -> void:
	_update_status_indicator(delta)
	# Session timer redraw every frame (follows head bone)
	if _session_control and _parent:
		_session_control.queue_redraw()
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
		var base_text = _status_label.text
		var dot_start = base_text.find(".")
		if dot_start > 0:
			base_text = base_text.substr(0, dot_start)
		_status_label.text = base_text + dots
	var alpha = 0.5 + 0.4 * sin(Time.get_ticks_msec() * 0.004)
	_status_label.modulate = Color(1, 1, 1, alpha)

# ─── Session Timer Display (Above Tama's Head) ──────────
# Uses the projected head bone position from main.gd (head_screen_pos).
# Draws a compact timer + mini arc that floats above her head.

func _setup_session_display() -> void:
	_session_canvas = CanvasLayer.new()
	_session_canvas.layer = 50
	_render_target.add_child(_session_canvas)
	_session_control = Control.new()
	_session_control.name = "SessionDisplay"
	_session_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_session_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_session_control.connect("draw", _draw_session_display)
	_session_canvas.add_child(_session_control)

func _draw_session_display() -> void:
	if _parent == null or not _parent.session_active or _parent.session_duration_secs <= 0:
		return

	var vp_size: Vector2
	if _render_target and _render_target is Window:
		vp_size = Vector2(_render_target.size)
	elif _parent:
		vp_size = _parent.get_viewport().get_visible_rect().size
	else:
		return

	var elapsed: int = _parent.session_elapsed_secs
	var total: int = _parent.session_duration_secs
	var remaining: int = maxi(total - elapsed, 0)
	var progress := clampf(float(elapsed) / float(total), 0.0, 1.0)
	var font := ThemeDB.fallback_font

	# ── Get head position (projected from 3D bone) ──
	var head_pos: Vector2 = _parent.head_screen_pos
	var center_x: float
	var timer_y: float

	if head_pos.x > 0 and head_pos.y > 0:
		# Head bone found — position ABOVE the head
		center_x = clampf(head_pos.x, 40.0, vp_size.x - 40.0)
		timer_y = head_pos.y - 110.0  # 110px above head bone (well above her head)
		# Clamp so it doesn't go off-screen
		timer_y = maxf(timer_y, 20.0)
	else:
		# Fallback: top-center of window
		center_x = vp_size.x * 0.5
		timer_y = 25.0

	# ════════════════════════════════════════════
	# FLOATING SESSION TIMER
	# ════════════════════════════════════════════

	# ── Time remaining text ──
	var r_min: int = remaining / 60
	var r_sec: int = remaining % 60
	var time_str: String = "%d:%02d" % [r_min, r_sec]
	var time_font_size: int = 14
	var ts := font.get_string_size(time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, time_font_size)

	# Color shifts based on progress
	var accent_color: Color
	if progress > 0.9:
		accent_color = Color(0.3, 1.0, 0.5, 0.9)   # Green — almost done!
	elif progress > 0.75:
		accent_color = Color(0.4, 0.85, 0.6, 0.85)  # Teal
	else:
		accent_color = Color(0.4, 0.7, 1.0, 0.85)   # Blue

	var text_x: float = center_x - ts.x * 0.5
	var text_y: float = timer_y

	# ── Pill background (rounded rect behind text) ──
	var pill_padding_h: float = 12.0
	var pill_padding_v: float = 5.0
	var pill_rect := Rect2(
		text_x - pill_padding_h,
		text_y - ts.y - pill_padding_v,
		ts.x + pill_padding_h * 2.0,
		ts.y + pill_padding_v * 2.0
	)
	# Dark semi-transparent background
	_session_control.draw_rect(pill_rect, Color(0.05, 0.08, 0.14, 0.55), true)
	# Subtle border
	_session_control.draw_rect(pill_rect, Color(accent_color.r, accent_color.g, accent_color.b, 0.2), false, 1.0)

	# ── Draw time text ──
	_session_control.draw_string(font, Vector2(text_x, text_y),
		time_str, HORIZONTAL_ALIGNMENT_LEFT, -1, time_font_size, accent_color)

	# ── Mini progress bar under the pill ──
	var bar_w: float = pill_rect.size.x - 8.0
	var bar_h: float = 2.5
	var bar_x: float = pill_rect.position.x + 4.0
	var bar_y: float = pill_rect.position.y + pill_rect.size.y + 3.0

	# Track
	_session_control.draw_rect(
		Rect2(bar_x, bar_y, bar_w, bar_h),
		Color(0.15, 0.2, 0.3, 0.3)
	)
	# Fill
	if progress > 0.005:
		_session_control.draw_rect(
			Rect2(bar_x, bar_y, bar_w * progress, bar_h),
			accent_color
		)
		# Tiny glow dot at progress tip
		var tip_x := bar_x + bar_w * progress
		_session_control.draw_circle(
			Vector2(tip_x, bar_y + bar_h * 0.5), 2.0,
			Color(accent_color.r, accent_color.g, accent_color.b, 0.6)
		)


# ─── Break Overlay ───────────────────────────────────────

func _setup_break_overlay() -> void:
	_break_canvas = CanvasLayer.new()
	_break_canvas.layer = 55
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
		Color(0.1, 0.15, 0.25, 0.12)
	)

	# ── Break timer (above head, same position logic) ──
	var font := ThemeDB.fallback_font
	var mins := int(remaining) / 60
	var secs := int(remaining) % 60
	var time_str := "☕ %d:%02d" % [mins, secs]
	var font_size := 16
	var ts := font.get_string_size(time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)

	var head_pos: Vector2 = _parent.head_screen_pos if _parent else Vector2(-1, -1)
	var center_x: float
	var timer_y: float
	if head_pos.x > 0 and head_pos.y > 0:
		center_x = clampf(head_pos.x, 50.0, vp_size.x - 50.0)
		timer_y = head_pos.y - 75.0  # Higher than session timer
		timer_y = maxf(timer_y, 20.0)
	else:
		center_x = vp_size.x * 0.5
		timer_y = 20.0

	var text_x := center_x - ts.x * 0.5
	var text_y := timer_y

	# Pill background
	var pill := Rect2(text_x - 14, text_y - ts.y - 6, ts.x + 28, ts.y + 14)
	var text_color := Color(0.4, 0.7, 1.0, 0.9).lerp(Color(0.3, 1.0, 0.5, 0.9), progress)
	_break_control.draw_rect(pill, Color(0.08, 0.1, 0.18, 0.65), true)
	_break_control.draw_rect(pill, Color(text_color.r, text_color.g, text_color.b, 0.25), false, 1.0)
	_break_control.draw_string(font, Vector2(text_x, text_y), time_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

	# Progress bar under pill
	var bar_w := pill.size.x - 8.0
	var bar_h := 3.0
	var bar_x := pill.position.x + 4.0
	var bar_y := pill.position.y + pill.size.y + 3.0
	_break_control.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.2, 0.25, 0.35, 0.4))
	_break_control.draw_rect(Rect2(bar_x, bar_y, bar_w * progress, bar_h), text_color)

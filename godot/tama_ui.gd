extends Node
## Tama UI — Status indicator + Break overlay
##
## Manages overlay UI elements that are independent of character behavior.

# ─── State ───────────────────────────────────────────────
var _status_label: Label
var _status_canvas: CanvasLayer
var _status_visible: bool = false
var _status_dots: int = 0
var _status_timer: float = 0.0



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
	_setup_break_overlay()

func update(delta: float) -> void:
	_update_status_indicator(delta)
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
	_status_label.add_theme_color_override("font_color", Color(0.345, 0.537, 0.769, 0.9))  # #5889c4
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

	# ── Soft background tint (retro blue) ──
	_break_control.draw_rect(
		Rect2(Vector2.ZERO, vp_size),
		Color(0.502, 0.682, 0.890, 0.08)  # #80aee3 subtle
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

	# Pill background (retro style)
	var pill := Rect2(text_x - 14, text_y - ts.y - 6, ts.x + 28, ts.y + 14)
	var text_color := Color(0.345, 0.537, 0.769, 0.9).lerp(Color(0.533, 0.784, 0.627, 0.9), progress)  # #5889c4 → #88c8a0
	_break_control.draw_rect(pill, Color(0.906, 0.933, 0.965, 0.92), true)  # #e7eef6
	_break_control.draw_rect(pill, Color(0.502, 0.682, 0.890, 0.6), false, 2.0)  # #80aee3 border
	_break_control.draw_string(font, Vector2(text_x, text_y), time_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

	# Progress bar under pill
	var bar_w := pill.size.x - 8.0
	var bar_h := 3.0
	var bar_x := pill.position.x + 4.0
	var bar_y := pill.position.y + pill.size.y + 3.0
	_break_control.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.553, 0.737, 0.918, 0.3))  # #8dbcea ghost
	_break_control.draw_rect(Rect2(bar_x, bar_y, bar_w * progress, bar_h), text_color)

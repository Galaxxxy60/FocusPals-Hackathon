# 🖱️ FocusPals — Click-Through System Guide

## ⚠️ READ THIS BEFORE adding ANY new UI panel, overlay, or interactive element.

FocusPals uses a **dual-layer click-through system** (Win32 + Godot) that WILL break
if not handled correctly. This is the #1 recurring bug in the project.

---

## How Click-Through Works (2 Layers)

```
┌─────────────────────────────────────────────────────────┐
│  LAYER 1: Win32 — WS_EX_TRANSPARENT (Python side)      │
│  Controls whether the OS sends clicks to our window.    │
│  ✅ ON  = clicks pass through to desktop apps           │
│  ❌ OFF = our window receives click events              │
│                                                         │
│  Controlled by: _toggle_click_through(True/False)       │
│  File: godot_bridge.py                                  │
├─────────────────────────────────────────────────────────┤
│  LAYER 2: Godot — WINDOW_FLAG_MOUSE_PASSTHROUGH         │
│  Controls whether Godot processes clicks or ignores.    │
│  BUT: on layered windows, transparent pixels STILL      │
│  pass through even with this OFF.                       │
│                                                         │
│  Controlled by: DisplayServer.window_set_flag(...)      │
│  File: wherever the panel opens                         │
├─────────────────────────────────────────────────────────┤
│  LAYER 2b: Pixel Transparency (gotcha!)                 │
│  WS_EX_LAYERED windows pass clicks on TRANSPARENT       │
│  pixels, even without WS_EX_TRANSPARENT.                │
│                                                         │
│  Fix: full-screen ColorRect(0,0,0, 0.01) with           │
│  mouse_filter = MOUSE_FILTER_STOP                       │
└─────────────────────────────────────────────────────────┘
```

**BOTH layers must be disabled for clicks to work on a panel.**

---

## The 3 Things You MUST Do For Any New Interactive Panel

### 1. 🔧 Python: Disable Win32 click-through

Send a WebSocket command to Python when the panel **opens** and **closes**:

```gdscript
# In your panel's _open():
main_node.ws.send_text(JSON.stringify({"command": "SHOW_MYPANEL"}))

# In your panel's _close():
main_node.ws.send_text(JSON.stringify({"command": "HIDE_MYPANEL"}))
```

Then in `godot_bridge.py`, handle the commands:

```python
elif cmd == "SHOW_MYPANEL":
    _toggle_click_through(False)
elif cmd == "HIDE_MYPANEL":
    _toggle_click_through(True)
```

### 2. 🎯 Godot: Full-screen click catcher

Your panel MUST have a **full-screen nearly-invisible background** that covers the
entire viewport. Without this, clicks on transparent pixels still pass through.

```gdscript
var _bg = ColorRect.new()
_bg.color = Color(0, 0, 0, 0.01)  # 1% opacity — invisible but blocks clicks
_bg.anchor_right = 1.0
_bg.anchor_bottom = 1.0
_bg.mouse_filter = Control.MOUSE_FILTER_STOP
_bg.gui_input.connect(func(event):
    if event is InputEventMouseButton and event.pressed:
        _close()  # Click outside = close
)
add_child(_bg)
```

### 3. 🛡️ Guard ALL exit paths that restore click-through

**This is the part everyone forgets.** When ANY other panel closes, it may
re-enable click-through. You must add guards:

#### In `main.gd` → `_on_radial_hide()`:

**CRITICAL**: Always send `HIDE_RADIAL` first (to reset Python state), THEN
conditionally restore passthrough. If you skip `HIDE_RADIAL`, Python's
`state["radial_shown"]` stays `True` and the edge monitor will **never** reopen the radial.

```gdscript
func _on_radial_hide() -> void:
    # ALWAYS send HIDE_RADIAL first — resets Python's radial_shown flag
    if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
        ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))
    # Then check if any panel still needs clicks
    if settings_panel and settings_panel.is_open:
        return
    if debug_tweaks and debug_tweaks.is_open:   # ← ADD YOUR PANEL HERE
        return
    if _quit_layer:
        return
    _safe_restore_passthrough()
```

#### In Python `godot_bridge.py` → `HIDE_RADIAL` handler:

**CRITICAL**: Always reset `radial_shown`, but check ALL panel flags before
re-enabling click-through. Each interactive panel needs its own state flag.

```python
elif cmd == "HIDE_RADIAL":
    state["radial_shown"] = False
    state["_mouse_was_away"] = True
    state["_radial_cooldown_until"] = 0
    # Only re-enable click-through if NO panel needs clicks
    if (not state["_mic_panel_pending"]
        and not state.get("_tweaks_panel_open", False)
        and not state.get("_my_panel_open", False)):  # ← ADD YOUR FLAG
        _toggle_click_through(True)
    elif state["_mic_panel_pending"]:
        state["_mic_panel_pending"] = False
```

### 4. 🏷️ Python: Add a state flag for your panel

Every interactive panel needs a Python-side state flag:

```python
# In SHOW_MYPANEL handler:
state["_my_panel_open"] = True
_toggle_click_through(False)

# In HIDE_MYPANEL handler:
state["_my_panel_open"] = False
_toggle_click_through(True)
```

Then add that flag to ALL the guards in `HIDE_RADIAL` (see above).

---

## Complete Flow for Reference: How Settings Panel Works

```
1. Mouse → right edge → Python edge_monitor detects
2. Python: _toggle_click_through(False)     ← Win32 CT OFF
3. Python: sends SHOW_RADIAL via WS
4. Godot:  radial_menu.open()               ← Godot CT OFF
5. User clicks ⚙️ Settings
6. Godot:  sends GET_SETTINGS to Python
7. Python: _mic_panel_pending = True         ← GUARD FLAG SET
8. Python: _toggle_click_through(False)      ← Win32 CT OFF (redundant but safe)
9. Python: sends SETTINGS_DATA response
10. Godot: settings_panel.show_settings()
11. Radial auto-closes → _on_radial_hide()
12. Godot:  checks settings_panel.is_open → returns early ← GUARD WORKS
13. (No HIDE_RADIAL sent to Python)
14. User closes settings panel
15. Godot:  settings_panel.close() → panel_closed signal
16. Godot:  _safe_restore_passthrough()      ← Godot CT ON
17. Godot:  sends HIDE_RADIAL to Python
18. Python: _toggle_click_through(True)      ← Win32 CT ON
```

---

## Checklist: Adding a New Interactive Panel

- [ ] Panel has `var is_open := false` flag
- [ ] `_open()` sends WS command → Python calls `_toggle_click_through(False)`
- [ ] `_close()` sends WS command → Python calls `_toggle_click_through(True)`
- [ ] Python SHOW/HIDE handlers set `state["_my_panel_open"]` flag
- [ ] Full-screen `ColorRect(0,0,0, 0.01)` with `MOUSE_FILTER_STOP` added
- [ ] `_on_radial_hide()` checks `my_panel.is_open` before restoring passthrough
- [ ] `_safe_restore_passthrough()` checks `my_panel.is_open` → returns early
- [ ] Python `HIDE_RADIAL` handler checks `state["_my_panel_open"]` flag
- [ ] Panel's `_close()` calls `_safe_restore_passthrough()` (not direct flag set)
- [ ] Tested: open panel via F-key WITHOUT radial → clicks work
- [ ] Tested: open panel WITH radial visible → radial closes → clicks still work
- [ ] Tested: close panel → click-through is restored
- [ ] Tested: after closing panel → radial can reopen on mouse hover

---

## Common Bugs & Symptoms

| Symptom | Cause | Fix |
|---------|-------|-----|
| Panel visible but can't click anything | Win32 WS_EX_TRANSPARENT still active | Send SHOW command to Python |
| Clicks work on panel but not on sliders | Missing full-screen click catcher bg | Add ColorRect(0,0,0,0.01) |
| Panel works at first, then stops | Another panel closing re-enabled CT | Add guard to `_on_radial_hide` + Python flag |
| Click-through never restored after close | Missing HIDE command to Python | Send HIDE command in `_close()` |
| Radial won't reopen after using panel | `HIDE_RADIAL` never sent → `radial_shown` stuck True | Always send HIDE_RADIAL first in `_on_radial_hide` |
| Intermittent: works sometimes | Race between SHOW/HIDE WS messages | Use state flags, not timing |

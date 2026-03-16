"""
FocusPals — App Control (Jarvis Mode) 🤖
OS-level application control: open, switch, minimize, shortcuts, typing, URLs, volume.
Tama can help the user inside his apps — not just watch him.
"""

import ctypes
import ctypes.wintypes
import os
import subprocess
import sys
import time
import webbrowser

import pyautogui
import pygetwindow as gw

# ─── App Registry ───────────────────────────────────────────
# Maps friendly names (lowercase) → executable paths or start commands
# Uses common install paths + Windows start menu shortcuts
APP_REGISTRY = {
    # IDEs / Code editors
    "vscode": "code",
    "vs code": "code",
    "visual studio code": "code",
    "cursor": "cursor",

    # Browsers
    "chrome": "chrome",
    "google chrome": "chrome",
    "firefox": "firefox",
    "edge": "msedge",
    "brave": "brave",
    "opera": "opera",

    # Creative
    "blender": "blender",
    "photoshop": "photoshop",
    "figma": "figma",
    "premiere": "premiere",
    "davinci": "resolve",

    # Productivity
    "word": "winword",
    "excel": "excel",
    "powerpoint": "powerpnt",
    "notion": "notion",
    "obsidian": "obsidian",
    "notepad": "notepad",
    "terminal": "wt",
    "powershell": "powershell",
    "cmd": "cmd",

    # Communication
    "discord": "discord",
    "slack": "slack",
    "teams": "teams",

    # Media
    "spotify": "spotify",

    # Gaming / Creative
    "godot": "godot",
    "unreal": "UnrealEditor",
    "steam": "steam",

    # System
    "explorateur": "explorer",
    "explorer": "explorer",
    "gestionnaire": "taskmgr",
    "task manager": "taskmgr",
    "calculatrice": "calc",
    "calculator": "calc",
    "paint": "mspaint",

    # FocusPals related
    "suno": None,  # Web app — handled via URL
}

# URLs for web apps
WEB_APPS = {
    "suno": "https://suno.com",
    "chatgpt": "https://chatgpt.com",
    "youtube": "https://youtube.com",
    "gmail": "https://mail.google.com",
    "google drive": "https://drive.google.com",
    "github": "https://github.com",
    "figma": "https://figma.com",
}

# ─── Shortcut Aliases ──────────────────────────────────────
# Maps natural language to keyboard shortcuts
SHORTCUT_ALIASES = {
    # FR aliases
    "sauvegarde": "ctrl+s",
    "sauvegarder": "ctrl+s",
    "enregistrer": "ctrl+s",
    "annuler": "ctrl+z",
    "refaire": "ctrl+y",
    "copier": "ctrl+c",
    "coller": "ctrl+v",
    "couper": "ctrl+x",
    "tout sélectionner": "ctrl+a",
    "chercher": "ctrl+f",
    "rechercher": "ctrl+f",
    "nouvel onglet": "ctrl+t",
    "nouveau fichier": "ctrl+n",
    "fermer onglet": "ctrl+w",

    # EN aliases
    "save": "ctrl+s",
    "undo": "ctrl+z",
    "redo": "ctrl+y",
    "copy": "ctrl+c",
    "paste": "ctrl+v",
    "cut": "ctrl+x",
    "select all": "ctrl+a",
    "find": "ctrl+f",
    "search": "ctrl+f",
    "new tab": "ctrl+t",
    "new file": "ctrl+n",
    "close tab": "ctrl+w",
}


# ─── Windows API ────────────────────────────────────────────
user32 = ctypes.windll.user32
SW_MINIMIZE = 6
SW_MAXIMIZE = 3
SW_RESTORE = 9
SW_SHOW = 5


def _get_screen_target(zone: str = "center") -> tuple:
    """Get fallback screen coordinates for the Jarvis hand animation.
    zone: 'center' (screen center), 'taskbar' (taskbar icon area),
          'tray' (system tray area, bottom-right)"""
    try:
        sw = user32.GetSystemMetrics(0)  # SM_CXSCREEN
        sh = user32.GetSystemMetrics(1)  # SM_CYSCREEN
    except Exception:
        sw, sh = 1920, 1080

    if zone == "taskbar":
        # Middle of the taskbar (where app icons appear)
        return sw // 2, sh - 24
    elif zone == "tray":
        # System tray area (bottom-right, near volume icon)
        return sw - 100, sh - 24
    else:
        # Screen center
        return sw // 2, sh // 2


def _find_window_by_name(name: str):
    """Find a window by partial title match (case-insensitive)."""
    name_lower = name.lower()
    try:
        windows = [w for w in gw.getAllWindows() if w.title and w.visible and w.width > 200]
        # Exact match first
        for w in windows:
            if name_lower == w.title.lower():
                return w
        # Partial match
        for w in windows:
            if name_lower in w.title.lower():
                return w
        # Reverse partial (window title contains search term)
        for w in windows:
            if any(part in w.title.lower() for part in name_lower.split()):
                return w
    except Exception:
        pass
    return None


def _find_in_program_files(name: str) -> str | None:
    """Search Program Files directories for an executable matching the app name.
    Handles version-specific names like 'Blender 5.0' by scanning folder names.
    Prioritizes exact version matches over generic ones."""
    import glob
    import re

    name_lower = name.lower().strip()

    # Common exe names for known apps
    EXE_NAMES = {
        "blender": "blender.exe",
        "godot": "godot.exe",
        "gimp": "gimp-*.exe",
        "inkscape": "inkscape.exe",
        "obs": "obs64.exe",
        "audacity": "audacity.exe",
        "krita": "krita.exe",
    }

    # Extract base app name (strip version: "blender 5.0" → "blender")
    base_name = re.sub(r'\s*[\d.]+\s*$', '', name_lower).strip()
    exe_name = EXE_NAMES.get(base_name, f"{base_name}.exe")

    # Dirs to search — installed AND portable locations
    home = os.path.expanduser("~")
    search_dirs = [
        # Standard install locations
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        os.path.join(os.environ.get("LocalAppData", ""), "Programs"),
        # Portable / user locations
        os.path.join(home, "Desktop"),
        os.path.join(home, "Downloads"),
        os.path.join(home, "Documents"),
        os.path.join(home, "Apps"),
        os.path.join(home, "Portable"),
        # Common external drives / custom dirs
        r"D:\Programs",
        r"D:\Apps",
        r"D:\Portable",
        os.path.join(home, "Downloads", "Compressed"),
    ]

    # Collect ALL candidate exe paths with a match score
    candidates = []  # list of (score, path)

    for prog_dir in search_dirs:
        if not os.path.isdir(prog_dir):
            continue
        try:
            for entry in os.scandir(prog_dir):
                if not entry.is_dir():
                    continue
                folder_lower = entry.name.lower()

                # Must contain the base app name
                if base_name not in folder_lower:
                    continue

                # Check exe directly in this folder
                exe_path = os.path.join(entry.path, exe_name)
                for match in glob.glob(exe_path):
                    score = 10 if name_lower in folder_lower else 5
                    candidates.append((score, match))

                # Check subfolders (e.g. "Blender Foundation/Blender 5.0/")
                try:
                    for sub in os.scandir(entry.path):
                        if not sub.is_dir():
                            continue
                        sub_lower = sub.name.lower()
                        if base_name not in sub_lower:
                            continue
                        sub_exe = os.path.join(sub.path, exe_name)
                        for match in glob.glob(sub_exe):
                            # Exact full name match = highest score
                            if name_lower == sub_lower:
                                score = 100  # Perfect match: "blender 5.0" == "blender 5.0"
                            elif name_lower in sub_lower:
                                score = 50   # Contains match
                            else:
                                score = 10   # Base name match only
                            candidates.append((score, match))
                except OSError:
                    pass
        except OSError:
            continue

    if not candidates:
        return None

    # Return the highest-scoring match
    candidates.sort(key=lambda x: x[0], reverse=True)
    print(f"  🤖 Program Files candidates: {[(s, os.path.basename(os.path.dirname(p))) for s, p in candidates[:5]]}")
    return candidates[0][1]

def _launch_and_verify(cmd, name: str, shell: bool = False) -> dict | None:
    """Launch a command and verify it actually started (didn't crash in <0.5s).
    Returns a result dict on success, None on failure."""
    try:
        if isinstance(cmd, str) and not shell:
            proc = subprocess.Popen([cmd])
        else:
            proc = subprocess.Popen(cmd, shell=shell,
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        # Wait briefly to see if it crashes immediately
        time.sleep(0.5)
        exit_code = proc.poll()
        if exit_code is not None and exit_code != 0:
            # Process launched but crashed immediately
            print(f"  🤖 Process '{name}' crashed immediately (exit code {exit_code})")
            return None
        # Still running (or exited cleanly) → success
        return {"launched": True}
    except FileNotFoundError:
        return None
    except OSError:
        return None
    except Exception as e:
        print(f"  🤖 Launch error for '{name}': {e}")
        return None


def open_application(name: str) -> dict:
    """Simple app launch: try registry + os.startfile + where.
    If it fails, Gemini should use find_app to discover the right path, then run_exe."""
    name_lower = name.lower().strip()
    tx, ty = _get_screen_target("center")

    # Check web apps first
    if name_lower in WEB_APPS:
        url = WEB_APPS[name_lower]
        webbrowser.open(url)
        return {"status": "success", "action": "open_app", "message": f"Opened {name} in browser ({url})",
                "target_x": tx, "target_y": ty}

    # Check registry (exact match)
    cmd = APP_REGISTRY.get(name_lower)

    if cmd:
        # Try os.startfile (handles Windows associations)
        try:
            os.startfile(cmd)
            return {"status": "success", "action": "open_app", "message": f"Opened {name}",
                    "target_x": tx, "target_y": ty}
        except OSError:
            pass
        # Try via where + verify
        result = _launch_and_verify(cmd, name, shell=True)
        if result:
            return {"status": "success", "action": "open_app", "message": f"Launched {name}",
                    "target_x": tx, "target_y": ty}

    # Not in registry — try os.startfile with raw name
    try:
        os.startfile(name_lower)
        return {"status": "success", "action": "open_app", "message": f"Opened {name}",
                "target_x": tx, "target_y": ty}
    except OSError:
        pass

    # Failed — tell Gemini to use find_app to search, then run_exe with the right path
    return {"status": "error", "action": "open_app",
            "message": f"'{name}' not found in registry. Use find_app to search for it, then run_exe with the exact path."}


def find_app(name: str) -> dict:
    """Search the system for an app by name. Returns a list of found executables.
    Gemini uses this to discover available versions/paths before launching with run_exe."""
    import re
    name_lower = name.lower().strip()
    base_name = re.sub(r'\s*[\d.]+\s*$', '', name_lower).strip()

    EXE_NAMES = {
        "blender": "blender.exe", "godot": "godot.exe", "gimp": "gimp-*.exe",
        "inkscape": "inkscape.exe", "obs": "obs64.exe", "audacity": "audacity.exe",
        "krita": "krita.exe", "firefox": "firefox.exe", "chrome": "chrome.exe",
    }
    exe_name = EXE_NAMES.get(base_name, f"{base_name}.exe")

    home = os.path.expanduser("~")
    search_dirs = [
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        os.path.join(os.environ.get("LocalAppData", ""), "Programs"),
        os.path.join(home, "Desktop"),
        os.path.join(home, "Downloads"),
        os.path.join(home, "Downloads", "Compressed"),
        os.path.join(home, "Documents"),
        os.path.join(home, "Apps"),
    ]

    import glob
    found = []  # list of {"path": ..., "folder": ..., "version_hint": ...}

    for prog_dir in search_dirs:
        if not os.path.isdir(prog_dir):
            continue
        try:
            for entry in os.scandir(prog_dir):
                if not entry.is_dir():
                    continue
                folder_lower = entry.name.lower()
                if base_name not in folder_lower:
                    continue

                # Check exe directly
                for match in glob.glob(os.path.join(entry.path, exe_name)):
                    found.append({"path": match, "folder": entry.name})

                # Check subfolders (e.g. "Blender Foundation/Blender 5.0/")
                try:
                    for sub in os.scandir(entry.path):
                        if sub.is_dir() and base_name in sub.name.lower():
                            for match in glob.glob(os.path.join(sub.path, exe_name)):
                                found.append({"path": match, "folder": sub.name})
                except OSError:
                    pass
        except OSError:
            continue

    # Also check PATH via 'where'
    try:
        where_result = subprocess.run(["where", exe_name.replace("*", "")],
                                       capture_output=True, text=True, timeout=3)
        if where_result.returncode == 0:
            for line in where_result.stdout.strip().split('\n'):
                path = line.strip()
                if path and path not in [f["path"] for f in found]:
                    found.append({"path": path, "folder": "PATH"})
    except Exception:
        pass

    if not found:
        return {"status": "not_found", "action": "find_app",
                "message": f"No '{name}' executable found on this system.",
                "results": []}

    return {"status": "success", "action": "find_app",
            "message": f"Found {len(found)} match(es) for '{name}'",
            "results": [{"path": f["path"], "folder": f["folder"]} for f in found]}


def run_exe(path: str) -> dict:
    """Run a specific executable by its full path. Gemini uses this after find_app."""
    tx, ty = _get_screen_target("center")

    if not os.path.isfile(path):
        return {"status": "error", "action": "run_exe",
                "message": f"File not found: {path}"}

    result = _launch_and_verify(path, os.path.basename(path))
    if result:
        folder = os.path.basename(os.path.dirname(path))
        return {"status": "success", "action": "run_exe",
                "message": f"Launched {os.path.basename(path)} ({folder})",
                "target_x": tx, "target_y": ty}
    else:
        return {"status": "error", "action": "run_exe",
                "message": f"Process crashed immediately: {path}"}


def switch_to_window(title: str) -> dict:
    """Bring a window to the foreground by title."""
    if title.lower() == "current":
        return {"status": "success", "action": "switch_window", "message": "Already on current window"}

    win = _find_window_by_name(title)
    if not win:
        return {"status": "error", "action": "switch_window", "message": f"Window '{title}' not found"}

    try:
        hwnd = win._hWnd
        # Restore if minimized
        if user32.IsIconic(hwnd):
            user32.ShowWindow(hwnd, SW_RESTORE)
            time.sleep(0.1)
        # Bring to front
        user32.SetForegroundWindow(hwnd)
        return {"status": "success", "action": "switch_window", "message": f"Switched to '{win.title}'",
                "target_x": win.left + win.width // 2, "target_y": win.top + 30}
    except Exception as e:
        return {"status": "error", "action": "switch_window", "message": str(e)}


def minimize_window(title: str) -> dict:
    """Minimize a window."""
    if title.lower() == "current":
        try:
            hwnd = user32.GetForegroundWindow()
            user32.ShowWindow(hwnd, SW_MINIMIZE)
            # Get window rect for visual target
            rect = ctypes.wintypes.RECT()
            ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
            return {"status": "success", "action": "minimize",
                    "message": "Minimized current window",
                    "target_x": rect.right - 75, "target_y": rect.top + 15}
        except Exception as e:
            return {"status": "error", "action": "minimize", "message": str(e)}

    win = _find_window_by_name(title)
    if not win:
        return {"status": "error", "action": "minimize", "message": f"Window '{title}' not found"}

    try:
        user32.ShowWindow(win._hWnd, SW_MINIMIZE)
        return {"status": "success", "action": "minimize", "message": f"Minimized '{win.title}'",
                "target_x": win.left + win.width - 75, "target_y": win.top + 15}
    except Exception as e:
        return {"status": "error", "action": "minimize", "message": str(e)}


def maximize_window(title: str) -> dict:
    """Maximize a window."""
    if title.lower() == "current":
        try:
            hwnd = user32.GetForegroundWindow()
            user32.ShowWindow(hwnd, SW_MAXIMIZE)
            rect = ctypes.wintypes.RECT()
            ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
            return {"status": "success", "action": "maximize",
                    "message": "Maximized current window",
                    "target_x": rect.right - 45, "target_y": rect.top + 15}
        except Exception as e:
            return {"status": "error", "action": "maximize", "message": str(e)}

    win = _find_window_by_name(title)
    if not win:
        return {"status": "error", "action": "maximize", "message": f"Window '{title}' not found"}

    try:
        user32.ShowWindow(win._hWnd, SW_MAXIMIZE)
        return {"status": "success", "action": "maximize", "message": f"Maximized '{win.title}'",
                "target_x": win.left + win.width - 45, "target_y": win.top + 15}
    except Exception as e:
        return {"status": "error", "action": "maximize", "message": str(e)}


def send_shortcut(keys: str) -> dict:
    """Send a keyboard shortcut (e.g. 'ctrl+s', 'alt+f4')."""
    # Resolve aliases
    keys_lower = keys.lower().strip()
    resolved = SHORTCUT_ALIASES.get(keys_lower, keys_lower)

    try:
        # Parse: ctrl+shift+s → ['ctrl', 'shift', 's']
        parts = [k.strip() for k in resolved.split("+")]
        pyautogui.hotkey(*parts)

        # Compute target: center of active window (shortcut applies there)
        target_x, target_y = 960, 540  # fallback
        try:
            hwnd = user32.GetForegroundWindow()
            rect = ctypes.wintypes.RECT()
            ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
            target_x = (rect.left + rect.right) // 2
            target_y = (rect.top + rect.bottom) // 2
        except Exception:
            pass

        return {"status": "success", "action": "shortcut",
                "message": f"Sent {resolved}",
                "target_x": target_x, "target_y": target_y}
    except Exception as e:
        return {"status": "error", "action": "shortcut", "message": f"Failed to send '{resolved}': {e}"}


def type_text(text: str) -> dict:
    """Type text into the active window."""
    try:
        # Use pyperclip + Ctrl+V for Unicode support (pyautogui.typewrite is ASCII only)
        import pyperclip
        pyperclip.copy(text)
        time.sleep(0.05)
        pyautogui.hotkey("ctrl", "v")

        target_x, target_y = 960, 540
        try:
            hwnd = user32.GetForegroundWindow()
            rect = ctypes.wintypes.RECT()
            ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
            target_x = (rect.left + rect.right) // 2
            target_y = (rect.top + rect.bottom) // 2
        except Exception:
            pass

        return {"status": "success", "action": "type_text",
                "message": f"Typed '{text[:50]}{'...' if len(text) > 50 else ''}'",
                "target_x": target_x, "target_y": target_y}
    except Exception as e:
        return {"status": "error", "action": "type_text", "message": str(e)}


def open_url(url: str) -> dict:
    """Open a URL in the default browser."""
    try:
        # Add https if no protocol
        if not url.startswith("http://") and not url.startswith("https://"):
            url = "https://" + url
        webbrowser.open(url)
        tx, ty = _get_screen_target("center")
        return {"status": "success", "action": "open_url", "message": f"Opened {url}",
                "target_x": tx, "target_y": ty}
    except Exception as e:
        return {"status": "error", "action": "open_url", "message": str(e)}


def search_web(query: str) -> dict:
    """Open a Google search for the given query."""
    try:
        import urllib.parse
        search_url = f"https://www.google.com/search?q={urllib.parse.quote(query)}"
        webbrowser.open(search_url)
        tx, ty = _get_screen_target("center")
        return {"status": "success", "action": "search_web", "message": f"Searched: {query}",
                "target_x": tx, "target_y": ty}
    except Exception as e:
        return {"status": "error", "action": "search_web", "message": str(e)}


def take_screenshot(save_path: str = None) -> dict:
    """Take a screenshot and save it or copy to clipboard."""
    try:
        import mss
        from PIL import Image

        with mss.mss() as sct:
            monitor = sct.monitors[0]  # All monitors
            screenshot = sct.grab(monitor)
            img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)

        if save_path and save_path.lower() != "clipboard":
            if not save_path.endswith((".png", ".jpg")):
                save_path = os.path.join(os.path.expanduser("~"), "Desktop", f"screenshot_{int(time.time())}.png")
            img.save(save_path)
            tx, ty = _get_screen_target("center")
            return {"status": "success", "action": "screenshot", "message": f"Screenshot saved to {save_path}",
                    "target_x": tx, "target_y": ty}
        else:
            # Copy to clipboard via PowerShell
            temp_path = os.path.join(os.environ.get("TEMP", "/tmp"), "tama_screenshot.png")
            img.save(temp_path)
            try:
                ps_cmd = f'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetImage([System.Drawing.Image]::FromFile("{temp_path}"))'
                subprocess.run(["powershell", "-command", ps_cmd], timeout=5, capture_output=True)
            except Exception:
                pass
            tx, ty = _get_screen_target("center")
            return {"status": "success", "action": "screenshot", "message": "Screenshot copied to clipboard",
                    "target_x": tx, "target_y": ty}
    except Exception as e:
        return {"status": "error", "action": "screenshot", "message": str(e)}


def adjust_volume(action: str) -> dict:
    """Adjust system volume: up, down, mute."""
    try:
        VK_VOLUME_UP = 0xAF
        VK_VOLUME_DOWN = 0xAE
        VK_VOLUME_MUTE = 0xAD

        action_lower = action.lower().strip()
        tx, ty = _get_screen_target("tray")
        if action_lower in ("up", "10", "monte", "plus"):
            # Press volume up 5 times (~10% increase)
            for _ in range(5):
                user32.keybd_event(VK_VOLUME_UP, 0, 0, 0)
                user32.keybd_event(VK_VOLUME_UP, 0, 2, 0)
                time.sleep(0.02)
            return {"status": "success", "action": "volume", "message": "Volume up",
                    "target_x": tx, "target_y": ty}
        elif action_lower in ("down", "-10", "baisse", "moins"):
            for _ in range(5):
                user32.keybd_event(VK_VOLUME_DOWN, 0, 0, 0)
                user32.keybd_event(VK_VOLUME_DOWN, 0, 2, 0)
                time.sleep(0.02)
            return {"status": "success", "action": "volume", "message": "Volume down",
                    "target_x": tx, "target_y": ty}
        elif action_lower in ("mute", "muet", "silence", "toggle"):
            user32.keybd_event(VK_VOLUME_MUTE, 0, 0, 0)
            user32.keybd_event(VK_VOLUME_MUTE, 0, 2, 0)
            return {"status": "success", "action": "volume", "message": "Volume mute toggled",
                    "target_x": tx, "target_y": ty}
        else:
            return {"status": "error", "action": "volume", "message": f"Unknown volume action: {action}"}
    except Exception as e:
        return {"status": "error", "action": "volume", "message": str(e)}


# ─── Main Dispatcher ────────────────────────────────────────

def execute_action(action: str, target: str) -> dict:
    """
    Main dispatcher — routes app_control tool calls to the right function.
    Returns a dict with: status, action, message, and optionally target_x/target_y
    for the visual hand animation.
    """
    action_lower = action.lower().strip()

    if action_lower == "open_app":
        return open_application(target)
    elif action_lower == "find_app":
        return find_app(target)
    elif action_lower == "run_exe":
        return run_exe(target)
    elif action_lower == "switch_window":
        return switch_to_window(target)
    elif action_lower == "minimize":
        return minimize_window(target)
    elif action_lower == "maximize":
        return maximize_window(target)
    elif action_lower == "shortcut":
        return send_shortcut(target)
    elif action_lower == "type_text":
        return type_text(target)
    elif action_lower == "open_url":
        return open_url(target)
    elif action_lower == "search_web":
        return search_web(target)
    elif action_lower == "screenshot":
        return take_screenshot(target)
    elif action_lower in ("volume_up", "volume_down", "volume_mute"):
        vol_action = action_lower.replace("volume_", "")
        return adjust_volume(vol_action)
    else:
        return {"status": "error", "action": action_lower, "message": f"Unknown action: {action}"}

"""
FocusPals — Tab/Window Close Action 🖐️→👆
Ferme l'onglet ou la fenêtre ciblée.
La partie visuelle (main animée) est maintenant gérée par Godot multi-window.
Ce script ne fait QUE la fermeture fonctionnelle.
"""

import time
import sys
import ctypes
import ctypes.wintypes

# ─── DPI Awareness ───────────────────────────────────────────
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

# ─── Windows API ─────────────────────────────────────────────
user32 = ctypes.windll.user32
WM_CLOSE = 0x0010


def close_target(hwnd, mode="app"):
    """Close the target tab or window."""
    hwnd = int(hwnd)

    if not user32.IsWindow(hwnd):
        print("⚠️ Fenêtre déjà fermée.")
        return

    if mode == "browser":
        # Ctrl+W = ferme UN SEUL onglet
        user32.keybd_event(0x12, 0, 0, 0)   # Alt press
        user32.keybd_event(0x12, 0, 2, 0)   # Alt release
        time.sleep(0.05)
        user32.SetForegroundWindow(hwnd)
        time.sleep(0.15)

        import pyautogui
        pyautogui.hotkey('ctrl', 'w')
        print(f"✅ Ctrl+W envoyé (onglet fermé) hwnd={hwnd}")
    else:
        # WM_CLOSE = ferme toute la fenêtre
        user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
        print(f"✅ WM_CLOSE envoyé (app fermée) hwnd={hwnd}")


# ─── CLI ─────────────────────────────────────────────────────
if __name__ == '__main__':
    if len(sys.argv) >= 3:
        close_target(sys.argv[1], sys.argv[2])
    elif len(sys.argv) == 2:
        close_target(sys.argv[1], "app")
    else:
        print("Usage: hand_animation.py <hwnd> [browser|app]")

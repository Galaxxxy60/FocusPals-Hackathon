"""
Applique le flag WS_EX_TRANSPARENT sur la fenêtre FocusPals Godot
pour permettre le click-through sur Windows.
Lance ce script APRÈS avoir lancé focuspals.exe
"""
import ctypes
import ctypes.wintypes
import time
import sys

# Windows API
user32 = ctypes.windll.user32
GWL_EXSTYLE = -20
WS_EX_LAYERED = 0x80000
WS_EX_TRANSPARENT = 0x20
WS_EX_TOOLWINDOW = 0x80  # Cache la fenêtre de la barre des tâches

SetWindowLong = user32.SetWindowLongW
FindWindow = user32.FindWindowW
EnumWindows = user32.EnumWindows
GetWindowText = user32.GetWindowTextW
GetWindowTextLength = user32.GetWindowTextLengthW
IsWindowVisible = user32.IsWindowVisible

WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.wintypes.BOOL, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)

def find_godot_window():
    """Cherche la fenêtre FocusPals/Godot par son titre."""
    result = []
    
    def enum_callback(hwnd, lparam):
        if IsWindowVisible(hwnd):
            length = GetWindowTextLength(hwnd)
            if length > 0:
                title = ctypes.create_unicode_buffer(length + 1)
                GetWindowText(hwnd, title, length + 1)
                t = title.value.lower()
                # Cherche la fenêtre Godot du projet
                if "focuspals" in t or "foculpal" in t or "focupals" in t:
                    result.append(hwnd)
        return True
    
    EnumWindows(WNDENUMPROC(enum_callback), 0)
    return result[0] if result else None

def apply_click_through(hwnd):
    """Applique WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW."""
    SetWindowLong(hwnd, GWL_EXSTYLE, WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
    print(f"✅ Click-through + caché de la barre des tâches (handle: {hwnd})")

if __name__ == "__main__":
    print("🔍 Recherche de la fenêtre FocusPals...")
    
    # Attend que la fenêtre apparaisse (max 10 sec)
    for i in range(20):
        hwnd = find_godot_window()
        if hwnd:
            break
        time.sleep(0.5)
    
    if not hwnd:
        print("❌ Fenêtre FocusPals non trouvée ! Lance focuspals.exe d'abord.")
        sys.exit(1)
    
    apply_click_through(hwnd)
    print("🎯 Tu peux maintenant cliquer à travers Tama !")
    print("   (Laisse ce terminal ouvert)")

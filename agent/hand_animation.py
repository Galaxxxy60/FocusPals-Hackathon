"""
FocusPals — Hand Animation (UIA-Guided) 🖐️→👆
Système de guidage chirurgical pour fermer les onglets de distraction.

Deux modes :
  - BROWSER : Utilise UI Automation pour traquer l'onglet exact (TabItem)
  - APP     : Utilise GetWindowRect pour traquer une fenêtre standalone

La main suit la cible en temps réel, même si la fenêtre est déplacée.
"""

import tkinter as tk
import time
import sys
import math
import ctypes
import ctypes.wintypes

# ─── Windows API ─────────────────────────────────────────────
user32 = ctypes.windll.user32
WM_CLOSE = 0x0010

# ─── UIA : Cache global pour éviter de recréer Desktop() à chaque frame ──
_uia_tab_rect = None  # (left, top, right, bottom) du TabItem sélectionné

def refresh_uia_tab_rect(hwnd):
    """
    Trouve le TabItem sélectionné dans la fenêtre navigateur via UIA.
    Filtre les faux TabItems (ex: boutons YouTube "Tous", "Musique") 
    en ne gardant que ceux proches du haut de la fenêtre (vrais onglets).
    """
    global _uia_tab_rect
    try:
        from pywinauto.application import Application
        app = Application(backend="uia").connect(handle=hwnd)
        win = app.window(handle=hwnd)
        
        # Récupère le haut de la fenêtre pour filtrer les vrais onglets
        win_left, win_top, win_right, win_bottom = get_window_rect(hwnd)
        
        tabs = win.descendants(control_type="TabItem")
        for tab in tabs:
            try:
                rect = tab.rectangle()
                # ═══ FILTRE ANTI FAUX-POSITIFS ═══
                # Les vrais onglets du navigateur sont dans les ~80px du haut de la fenêtre
                # Les faux tabs (YouTube filters, etc.) sont bien plus bas dans la page
                if rect.top > win_top + 80:
                    continue
                    
                if tab.is_selected():
                    _uia_tab_rect = (rect.left, rect.top, rect.right, rect.bottom)
                    return
            except Exception:
                continue
    except Exception as e:
        print(f"⚠️ UIA refresh: {e}")

def get_window_rect(hwnd):
    """Coordonnées de la fenêtre via Win32 API."""
    rect = ctypes.wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return rect.left, rect.top, rect.right, rect.bottom

# ─── Easing ──────────────────────────────────────────────────
def ease_in_out(t):
    if t < 0.5:
        return 4 * t * t * t
    else:
        return 1 - math.pow(-2 * t + 2, 3) / 2

# ─── Animation Principale ───────────────────────────────────
def animate(hwnd, mode="app"):
    hwnd = int(hwnd)
    
    if not user32.IsWindow(hwnd):
        print("⚠️ Fenêtre déjà fermée.")
        return
    
    # ── Pré-calcul UIA avant de lancer l'animation ──
    if mode == "browser":
        print("🔍 Recherche UIA du TabItem sélectionné...")
        refresh_uia_tab_rect(hwnd)
        if _uia_tab_rect:
            print(f"✅ TabItem trouvé: rect={_uia_tab_rect}")
        else:
            print("⚠️ TabItem non trouvé, fallback sur coin fenêtre")
    
    # ── Tkinter overlay ──
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-transparentcolor", "white")
    root.configure(bg="white")
    
    label = tk.Label(root, text="🖐️", font=("Segoe UI Emoji", 45), bg="white")
    label.pack()
    
    screen_width = root.winfo_screenwidth()
    screen_height = root.winfo_screenheight()
    start_x = screen_width - 150
    start_y = screen_height - 150
    
    steps = 45
    
    for i in range(steps + 1):
        if not user32.IsWindow(hwnd):
            root.destroy()
            return
        
        t = i / float(steps)
        eased_t = ease_in_out(t)
        curve_offset = math.sin(t * math.pi) * 120
        
        # ═══ COORDONNÉES DE LA CIBLE ═══
        if mode == "browser" and _uia_tab_rect:
            # UIA: vise le bouton X de l'onglet (20px avant le bord droit du tab)
            left, top, right, bottom = _uia_tab_rect
            target_x = right - 50
            target_y = top + (bottom - top) // 2
            
            # Refresh UIA toutes les 15 frames (~225ms) pour suivre si la fenêtre bouge
            if i % 15 == 0 and i > 0:
                refresh_uia_tab_rect(hwnd)
        else:
            # Fallback: bouton X de la fenêtre (coin top-right)
            wl, wt, wr, wb = get_window_rect(hwnd)
            target_x = wr - 25
            target_y = wt + 15
        
        current_x = int(start_x + (target_x - start_x) * eased_t - curve_offset)
        current_y = int(start_y + (target_y - start_y) * eased_t)
        # Compense la taille de l'emoji : le "doigt" est au centre, pas en haut-gauche
        current_x -= 35
        current_y -= 30
        
        root.geometry(f"+{current_x}+{current_y}")
        root.update()
        time.sleep(0.015)
    
    # ═══ Arrivé sur le X ═══
    label.config(text="👆")
    root.update()
    time.sleep(0.2)
    
    # ═══ FERMETURE ═══
    if not user32.IsWindow(hwnd):
        root.destroy()
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
    
    time.sleep(0.2)
    root.destroy()

# ─── CLI ─────────────────────────────────────────────────────
if __name__ == '__main__':
    if len(sys.argv) >= 3:
        animate(sys.argv[1], sys.argv[2])
    elif len(sys.argv) == 2:
        animate(sys.argv[1], "app")
    else:
        print("Usage: hand_animation.py <hwnd> [browser|app]")

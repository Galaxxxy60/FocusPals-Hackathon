import tkinter as tk
import time
import pyautogui
import sys
import math
import ctypes
import ctypes.wintypes

# ─── Windows API pour re-cibler la bonne fenêtre ────────────
user32 = ctypes.windll.user32

def ease_in_out(t):
    if t < 0.5:
        return 4 * t * t * t
    else:
        return 1 - math.pow(-2 * t + 2, 3) / 2

def animate(target_x, target_y, target_hwnd=None):
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-transparentcolor", "white")
    root.configure(bg="white")
    
    label = tk.Label(root, text="🖐️", font=("Segoe UI Emoji", 45), bg="white")
    label.pack()
    
    screen_width, screen_height = root.winfo_screenwidth(), root.winfo_screenheight()
    
    start_x = screen_width - 150
    start_y = screen_height - 150
    
    target_x = max(0, min(target_x, screen_width - 50))
    target_y = max(0, min(target_y, screen_height - 50))
    
    steps = 45
    for i in range(steps + 1):
        t = i / float(steps)
        eased_t = ease_in_out(t)
        curve_offset = math.sin(t * math.pi) * 150 
        
        current_x = int(start_x + (target_x - start_x) * eased_t - curve_offset)
        current_y = int(start_y + (target_y - start_y) * eased_t)
        
        root.geometry(f"+{current_x}+{current_y}")
        root.update()
        time.sleep(0.015)
        
    # Arrivé sur l'onglet
    label.config(text="👆")
    root.update()
    time.sleep(0.15)
    
    # ═══ FIX: RE-CIBLE la bonne fenêtre avant Ctrl+W ═══
    if target_hwnd:
        hwnd = int(target_hwnd)
        # Vérifie que la fenêtre existe toujours
        if user32.IsWindow(hwnd):
            # Remet le focus sur la fenêtre bannière
            user32.SetForegroundWindow(hwnd)
            time.sleep(0.1)  # Laisse Windows changer le focus
            pyautogui.hotkey('ctrl', 'w')
        else:
            print("⚠️ Fenêtre déjà fermée, annulation.")
    else:
        # Fallback ancien comportement
        pyautogui.hotkey('ctrl', 'w')
    
    time.sleep(0.1)
    root.destroy()

if __name__ == '__main__':
    if len(sys.argv) == 4:
        # Nouvelle version: x, y, hwnd
        animate(int(sys.argv[1]), int(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) == 3:
        # Ancienne version: x, y
        animate(int(sys.argv[1]), int(sys.argv[2]))
    else:
        w, h = pyautogui.size()
        animate(w // 2, h // 2)

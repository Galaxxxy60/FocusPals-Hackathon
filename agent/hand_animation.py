import tkinter as tk
import time
import pyautogui
import sys
import math

def ease_in_out(t):
    # Cubic easing in/out
    if t < 0.5:
        return 4 * t * t * t
    else:
        return 1 - math.pow(-2 * t + 2, 3) / 2

def animate(target_x, target_y):
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-transparentcolor", "white")
    root.configure(bg="white")
    
    # Taille de la main plus raisonnable
    label = tk.Label(root, text="🖐️", font=("Segoe UI Emoji", 45), bg="white")
    label.pack()
    
    screen_width, screen_height = root.winfo_screenwidth(), root.winfo_screenheight()
    
    # La main apparaît toujours tout en bas à droite de l'écran principal
    start_x = screen_width - 150
    start_y = screen_height - 150
    
    # Sécurité pour ne pas cibler en dehors de l'écran
    target_x = max(0, min(target_x, screen_width - 50))
    target_y = max(0, min(target_y, screen_height - 50))
    
    steps = 45 # Plus d'images pour plus de fluidité
    for i in range(steps + 1):
        t = i / float(steps)
        eased_t = ease_in_out(t)
        
        # Trajectoire courbe (ajout d'une bosse sur l'axe X pour faire un joli mouvement de poignet)
        curve_offset = math.sin(t * math.pi) * 150 
        
        current_x = int(start_x + (target_x - start_x) * eased_t - curve_offset)
        current_y = int(start_y + (target_y - start_y) * eased_t)
        
        root.geometry(f"+{current_x}+{current_y}")
        root.update()
        time.sleep(0.015)
        
    # Arrivé sur l'onglet : on change l'emoji (clic)
    label.config(text="👆")
    root.update()
    time.sleep(0.15)
    
    # Frappe système
    pyautogui.hotkey('ctrl', 'w')
    time.sleep(0.1)
    
    root.destroy()

if __name__ == '__main__':
    if len(sys.argv) == 3:
        animate(int(sys.argv[1]), int(sys.argv[2]))
    else:
        # Fallback au milieu de l'écran si pas de coordonnées
        w, h = pyautogui.size()
        animate(w // 2, h // 2)

import tkinter as tk
import time
import pyautogui

def animate():
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-transparentcolor", "white")
    root.configure(bg="white")
    
    label = tk.Label(root, text="🖐️", font=("Segoe UI Emoji", 60), bg="white")
    label.pack()
    
    # Target center of screen
    w, h = pyautogui.size()
    target_x, target_y = w // 2, h // 2
    start_x, start_y = target_x + 400, target_y + 400
    
    steps = 30
    for i in range(steps):
        # Ease out interpolation
        t = i / float(steps)
        ease = t * (2 - t)
        
        x = int(start_x - (start_x - target_x) * ease)
        y = int(start_y - (start_y - target_y) * ease)
        root.geometry(f"+{x}+{y}")
        root.update()
        time.sleep(0.02)
        
    # Change to click
    label.config(text="👆")
    root.update()
    time.sleep(0.5)
    root.destroy()

if __name__ == '__main__':
    animate()

---
description: Build/export the Godot project to update focuspals.exe and focuspals.pck
---

# Build Godot Project

After any change to `godot/main.gd` or other Godot source files, run this to repackage.

The ONLY Godot project is at `Desktop\FocusPals\FocusPals\godot\`.

// turbo-all

1. Export the Godot project in headless mode:
```
& "C:\Users\xewi6\Downloads\Compressed\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" --headless --path "godot" --export-release "Windows Desktop" 2>&1
```
Working directory: `c:\Users\xewi6\Desktop\FocusPals\FocusPals`

2. Verify the .pck was updated:
```
Get-Item "godot\focuspals.pck" | Select-Object Name, Length, LastWriteTime
```
Working directory: `c:\Users\xewi6\Desktop\FocusPals\FocusPals`

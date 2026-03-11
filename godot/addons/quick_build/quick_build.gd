@tool
extends EditorPlugin

var build_button: Button = null

func _enter_tree() -> void:
	build_button = Button.new()
	build_button.text = "⚡ Build"
	build_button.tooltip_text = "Export release → focuspals.exe"
	build_button.pressed.connect(_on_build_pressed)
	# Add to the main toolbar (top bar)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, build_button)
	print("⚡ Quick Build plugin loaded")

func _exit_tree() -> void:
	if build_button:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, build_button)
		build_button.queue_free()
		build_button = null

func _on_build_pressed() -> void:
	print("⚡ Building focuspals.exe...")
	build_button.text = "⏳ Building..."
	build_button.disabled = true
	
	# Save all scenes first
	EditorInterface.save_all_scenes()
	
	# Run the export
	var godot_path := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	var output_path := project_path.path_join("focuspals.exe")
	
	var args := PackedStringArray([
		"--headless",
		"--export-release",
		"Windows Desktop",
		output_path,
		"--path",
		project_path
	])
	
	# Use a thread to avoid freezing the editor
	var thread := Thread.new()
	thread.start(_run_export.bind(godot_path, args, thread))

func _run_export(godot_path: String, args: PackedStringArray, thread: Thread) -> void:
	var output := []
	var exit_code := OS.execute(godot_path, args, output, true)
	
	# Schedule UI update on main thread
	call_deferred("_on_export_done", exit_code, "\n".join(output), thread)

func _on_export_done(exit_code: int, output: String, thread: Thread) -> void:
	thread.wait_to_finish()
	
	if exit_code == 0:
		build_button.text = "✅ Built!"
		print("⚡ Build SUCCESS!\n%s" % output)
	else:
		build_button.text = "❌ Failed!"
		push_warning("⚡ Build FAILED (exit %d):\n%s" % [exit_code, output])
	
	build_button.disabled = false
	
	# Reset button text after 3 seconds
	await get_tree().create_timer(3.0).timeout
	if build_button:
		build_button.text = "⚡ Build"

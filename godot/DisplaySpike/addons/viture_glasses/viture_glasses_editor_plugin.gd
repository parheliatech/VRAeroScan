@tool
extends EditorPlugin
## Hands the VitureGlasses Android library to Godot's Gradle export. At runtime the plugin
## is the "VitureGlasses" engine singleton; this file only matters at export time.
##
## The AAR in bin/ is built by godot/plugins/viture_glasses/build.sh and is not in git: it
## contains Viture's proprietary native libraries.

var _export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	func _get_name() -> String:
		return "VitureGlasses"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		# Relative to res://addons.
		return PackedStringArray(["viture_glasses/bin/viture_glasses-%s.aar" % ("debug" if debug else "release")])

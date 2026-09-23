#!/usr/bin/env bash
# Launch an installed Godot app directly onto the Viture glasses' display, at native
# resolution (1920x1080 in 2D, 3840x1080 in 3D) instead of letterboxed phone mirroring.
#
#   launch_on_glasses.sh [package]      default: org.vraeroscan.displayspike
#
# Set ADB_SERIAL for Wi-Fi adb (e.g. 192.168.86.114:5555). If the glasses stay black,
# check the phone for Android 16's "Mirror to external display?" prompt: until it is
# answered the display is disabled.
set -eu
pkg="${1:-org.vraeroscan.displayspike}"
adb="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
[ -n "${ADB_SERIAL:-}" ] && adb="$adb -s $ADB_SERIAL"

id=$($adb shell dumpsys display | grep -oE 'DisplayInfo\{"VITURE", displayId [0-9]+' | head -1 | grep -oE '[0-9]+$' || true)
if [ -z "$id" ]; then
    echo "No VITURE display found - are the glasses plugged into the phone?" >&2
    exit 1
fi
size=$($adb shell dumpsys display | grep -oE "DisplayInfo\{\"VITURE\", displayId $id[^}]*real [0-9]+ x [0-9]+" | grep -oE '[0-9]+ x [0-9]+$' | head -1)
echo "glasses: logical display $id, $size"

$adb shell am force-stop "$pkg"
$adb shell am start --display "$id" -n "$pkg/com.godot.game.GodotAppLauncher"

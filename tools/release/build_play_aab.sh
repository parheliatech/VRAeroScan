#!/usr/bin/env bash
# Build the signed Play Store bundle (vraeroscan.aab) from the "Android Play" export preset.
#
#   tools/release/build_play_aab.sh
#
# Needs the VitureGlasses plugin built first (godot/plugins/viture_glasses/build.sh ../../VRAeroScan)
# and the upload keystore's secrets in ~/.config/vraeroscan/signing.env, which sets
# GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD. Nothing secret is in the repository.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090
source "${VRAEROSCAN_SIGNING_ENV:-$HOME/.config/vraeroscan/signing.env}"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/opt/jdk-17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
cd "$root/godot/VRAeroScan"
godot --headless --path . --export-release "Android Play" vraeroscan.aab
ls -l vraeroscan.aab

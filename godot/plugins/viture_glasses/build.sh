#!/usr/bin/env bash
# Build the VitureGlasses plugin AAR and install the addon into a Godot project.
#
#   godot/plugins/viture_glasses/build.sh [godot project dir ...]
#
# Needs JDK 17 (Gradle 8.11 cannot run on 25) and Viture's native libraries in
# vendor/viture/lib/ (see PROJECT_NOTES.md). Output AARs are gitignored: they contain
# Viture's proprietary code.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# Resolve project paths now: the build below changes directory.
projects=()
for p in "$@"; do
    projects+=("$(cd "$p" && pwd)")
done
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/opt/jdk-17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

cd "$here"
./gradlew --quiet assembleDebug assembleRelease
cp build/outputs/aar/viture_glasses-debug.aar build/outputs/aar/viture_glasses-release.aar addon/bin/
echo "built: $(ls addon/bin/*.aar | xargs -n1 basename | tr '\n' ' ')"

for project in "${projects[@]}"; do
    dest="$project/addons/viture_glasses"
    mkdir -p "$dest"
    cp -r addon/. "$dest/"
    echo "installed addon into $dest"
done

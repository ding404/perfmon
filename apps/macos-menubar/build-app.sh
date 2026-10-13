#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
app_dir=${1:-"$repo_root/dist/PerformanceMonitor.app"}

cargo build --manifest-path "$repo_root/Cargo.toml" -p perfmon-ffi --release
swift build --package-path "$repo_root/apps/macos-menubar" -c release

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_root/apps/macos-menubar/.build/release/PerformanceMonitor" "$app_dir/Contents/MacOS/PerformanceMonitor"
cp "$repo_root/apps/macos-menubar/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_root/apps/macos-menubar/Resources/PerformanceMonitor.icns" "$app_dir/Contents/Resources/PerformanceMonitor.icns"

echo "Built $app_dir"

#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=build/ta-dam.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/ta-dam"
cp Info.plist "$APP/Contents/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
echo "Built $APP"

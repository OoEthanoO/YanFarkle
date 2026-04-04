#!/bin/bash

# Configuration
PROJECT_NAME="Farkle Apple.xcodeproj"
SCHEME_NAME="Farkle Apple"
BUILD_DIR="build"
DMG_NAME="Farkle.dmg"
APP_NAME="YanFarkle.app"

# Clean up previous builds
echo "Cleaning up..."
rm -rf "$BUILD_DIR"
rm -f "$DMG_NAME"

# Build the application
echo "Building $SCHEME_NAME..."
xcodebuild -project "$PROJECT_NAME" \
           -scheme "$SCHEME_NAME" \
           -configuration Release \
           -derivedDataPath "$BUILD_DIR" \
           -destination 'platform=macOS' \
           build

# Check if build succeeded
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build failed or .app not found at $APP_PATH"
    exit 1
fi

# Create a temporary directory for DMG packaging
echo "Preparing DMG structure..."
STAGING_DIR="dmg_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy the app to the staging area
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create a symlink to /Applications
ln -s /Applications "$STAGING_DIR/Applications"

# Create the DMG
echo "Creating DMG..."
hdiutil create -volname "$SCHEME_NAME" \
               -srcfolder "$STAGING_DIR" \
               -ov -format UDZO \
               "$DMG_NAME"

# Cleanup
echo "Cleaning up temporary files..."
rm -rf "$STAGING_DIR"

echo "Success! $DMG_NAME has been created."

#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Build the requested native RootHide package without altering other variants.
if [ "${1:-}" = "roothide" ]; then
    trap 'cp control.rootful control' EXIT
    cp control.roothide control
    make clean
    make package FINALPACKAGE=1 ARCHS=arm64e THEOS_PACKAGE_SCHEME=roothide
    exit 0
fi

echo "=== Building FridaManager ==="

# Build rootful (iphoneos-arm)
echo ""
echo "--- Building rootful (iphoneos-arm) ---"
cp control.rootful control
make clean
make package FINALPACKAGE=1

# Build rootless (iphoneos-arm64)
echo ""
echo "--- Building rootless (iphoneos-arm64) ---"
cp control.rootless control
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# Restore rootful control as default
cp control.rootful control

echo ""
echo "--- Renaming packages ---"
for f in packages/*_iphoneos-arm.deb; do
    [ -f "$f" ] && mv "$f" "${f%_iphoneos-arm.deb}_iphoneos-arm_rootful.deb"
done
for f in packages/*_iphoneos-arm64.deb; do
    [ -f "$f" ] && mv "$f" "${f%_iphoneos-arm64.deb}_iphoneos-arm64_rootless.deb"
done

echo ""
echo "=== Build complete ==="
echo "Packages are in: $(pwd)/packages/"
ls -la packages/*.deb 2>/dev/null || echo "No packages found — check build output above."

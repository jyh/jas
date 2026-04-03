#!/bin/bash
# Build the Jas Swift application
cd "$(dirname "$0")"
swift build
echo "Build complete. Run with: swift run Jas"

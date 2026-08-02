#!/bin/bash
# The geometry layer must stay testable without a UI framework. There is no
# separate module enforcing this (see Package.swift), so CI enforces it here.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rn --include='*.swift' -E '^\s*import (SwiftUI|UIKit|AppKit|CoreGraphics)' Sources/LazyLayoutKit/Geometry Sources/LazyLayoutKit/Layouts; then
    echo "error: the geometry and layout layers must not import a UI framework."
    exit 1
fi
echo "ok: geometry and layout layers are framework-free."

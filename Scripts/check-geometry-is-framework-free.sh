#!/bin/bash
# The geometry layer must stay testable without a UI framework, and text
# measurement must stay confined to the one layer that needs CoreText. There is
# no separate module enforcing either (see Package.swift), so CI enforces it here.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rn --include='*.swift' -E '^\s*import (SwiftUI|UIKit|AppKit|CoreGraphics|CoreText)' Sources/LazyLayoutKit/Geometry Sources/LazyLayoutKit/Layouts; then
    echo "error: the geometry and layout layers must not import a UI framework."
    exit 1
fi

# Text measurement is the only thing in the package that needs CoreText. Keeping
# it in one directory is what lets the layout layer stay pure arithmetic: layouts
# consume heights, they never compute them.
if grep -rn --include='*.swift' -E '^\s*import CoreText' Sources/LazyLayoutKit \
    | grep -v '^Sources/LazyLayoutKit/Text/'; then
    echo "error: CoreText may only be imported under Sources/LazyLayoutKit/Text."
    exit 1
fi

echo "ok: geometry and layout layers are framework-free, CoreText is confined to Text."

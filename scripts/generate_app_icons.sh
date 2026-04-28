#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <source-image.png> [output-dir]"
    echo "  source image should be at least 1024x1024"
    exit 1
fi

SOURCE="$1"
OUTPUT="${2:-AgentSwift/AgentSwift/Assets.xcassets/AppIcon.appiconset}"

if [[ ! -f "$SOURCE" ]]; then
    echo "Error: source image '$SOURCE' not found"
    exit 1
fi

mkdir -p "$OUTPUT"

resize() {
    local size=$1
    local name=$2
    sips -z "$size" "$size" "$SOURCE" --out "$OUTPUT/$name" > /dev/null
}

resize 16    "icon_16x16.png"
resize 32    "icon_16x16@2x.png"
resize 32    "icon_32x32.png"
resize 64    "icon_32x32@2x.png"
resize 128   "icon_128x128.png"
resize 256   "icon_128x128@2x.png"
resize 256   "icon_256x256.png"
resize 512   "icon_256x256@2x.png"
resize 512   "icon_512x512.png"
resize 1024  "icon_512x512@2x.png"

cat > "$OUTPUT/Contents.json" << 'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png",     "idiom" : "mac", "scale" : "1x", "size" : "16x16"   },
    { "filename" : "icon_16x16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16"   },
    { "filename" : "icon_32x32.png",     "idiom" : "mac", "scale" : "1x", "size" : "32x32"   },
    { "filename" : "icon_32x32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32"   },
    { "filename" : "icon_128x128.png",   "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png","idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",   "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png","idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",   "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png","idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

echo "Generated icons in $OUTPUT"

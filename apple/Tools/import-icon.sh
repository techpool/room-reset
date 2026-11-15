#!/bin/sh
# Resize the generated project icon into Apple's required catalog slots.
set -eu
cd "$(dirname "$0")/.."
source_icon=../web/assets/icon.png
catalog=Assets.xcassets/AppIcon.appiconset
cp "$source_icon" "$catalog/icon-1024.png"
for pixels in 16 32 64 128 256 512; do
    sips -z "$pixels" "$pixels" "$source_icon" --out "$catalog/icon-$pixels.png" >/dev/null
done
cat > "$catalog/Contents.json" <<'JSON'
{
  "images": [
    {"idiom":"universal","platform":"ios","size":"1024x1024","filename":"icon-1024.png"},
    {"idiom":"mac","size":"16x16","scale":"1x","filename":"icon-16.png"},
    {"idiom":"mac","size":"16x16","scale":"2x","filename":"icon-32.png"},
    {"idiom":"mac","size":"32x32","scale":"1x","filename":"icon-32.png"},
    {"idiom":"mac","size":"32x32","scale":"2x","filename":"icon-64.png"},
    {"idiom":"mac","size":"128x128","scale":"1x","filename":"icon-128.png"},
    {"idiom":"mac","size":"128x128","scale":"2x","filename":"icon-256.png"},
    {"idiom":"mac","size":"256x256","scale":"1x","filename":"icon-256.png"},
    {"idiom":"mac","size":"256x256","scale":"2x","filename":"icon-512.png"},
    {"idiom":"mac","size":"512x512","scale":"1x","filename":"icon-512.png"},
    {"idiom":"mac","size":"512x512","scale":"2x","filename":"icon-1024.png"}
  ],
  "info":{"version":1,"author":"xcode"}
}
JSON

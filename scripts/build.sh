#!/usr/bin/env bash
# Cross-compiles usbdebugd for Kindle/ARM KOReader targets into
# usbdebug.koplugin/bin/<bin_arch>/usbdebugd.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$repo_root/usbdebug.koplugin"

# bin_arch:GOARCH:GOARM
targets=(
    "armv6:arm:6"
    "armv7:arm:7"
    "arm64:arm64:"
)

for target in "${targets[@]}"; do
    IFS=":" read -r bin_arch goarch goarm <<<"$target"
    out_dir="$plugin_dir/bin/$bin_arch"
    mkdir -p "$out_dir"

    out_bin="$out_dir/usbdebugd"
    echo "Building usbdebugd for $bin_arch (GOARCH=$goarch${goarm:+ GOARM=$goarm})..."
    env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOARM="$goarm" \
        go build -C "$repo_root" -trimpath -ldflags="-s -w" -o "$out_bin" ./cmd/usbdebugd
    chmod +x "$out_bin"
    echo "  -> $out_bin ($(du -h "$out_bin" | cut -f1))"
done

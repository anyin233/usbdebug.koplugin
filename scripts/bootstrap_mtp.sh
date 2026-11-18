#!/usr/bin/env bash
# One-command first-time installer for usbdebug.koplugin over USB Mass Storage or MTP.
# Run once while the Kindle is exited out of KOReader (in stock USB/MTP mode),
# then reopen KOReader. Subsequent deploys can use USB SSH directly.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$repo_root/usbdebug.koplugin"

if [[ ! -x "$plugin_dir/bin/armv7/usbdebugd" ]]; then
    if command -v go >/dev/null 2>&1; then
        echo "Prebuilt daemon binaries not found; running scripts/build.sh..."
        "$repo_root/scripts/build.sh"
    else
        echo "error: usbdebug.koplugin/bin/armv7/usbdebugd is missing and Go is not installed." >&2
        echo "Download a prebuilt usbdebug.koplugin.zip from GitHub Releases or install Go 1.22+." >&2
        exit 1
    fi
fi

# 1. Legacy USB Mass Storage Kindle check
for mount_candidate in \
    /Volumes/Kindle \
    /media/*/Kindle \
    /run/media/*/*/Kindle \
    /mnt/kindle
do
    if [[ -d "$mount_candidate/koreader/plugins" ]]; then
        dest="$mount_candidate/koreader/plugins/usbdebug.koplugin"
        echo "Detected USB Mass Storage Kindle at $mount_candidate"
        mkdir -p "$dest"
        COPYFILE_DISABLE=1 tar -C "$plugin_dir" \
            --exclude='.DS_Store' \
            --exclude='._*' \
            -cf - . | tar -C "$dest" -xf -
        sync 2>/dev/null || true
        echo "Installed usbdebug.koplugin -> $dest"
        echo "Safely eject the Kindle and open KOReader to start USB debugging."
        exit 0
    fi
done

# 2. MTP-era Kindle (PW6, Scribe, Colorsoft, KT6, FW 5.16.3+)
mkdir -p "$repo_root/build"
mtp_tool="$repo_root/build/mtp_tool"

if [[ ! -x "$mtp_tool" ]] || [[ "$repo_root/tools/mtp_tool.c" -nt "$mtp_tool" ]]; then
    if ! command -v clang >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
        echo "error: C compiler (clang/gcc) not found to build tools/mtp_tool.c" >&2
        exit 1
    fi
    cc="$(command -v clang || command -v gcc)"
    cflags=()
    ldflags=()
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libmtp; then
        read -ra cflags <<<"$(pkg-config --cflags libmtp)"
        read -ra ldflags <<<"$(pkg-config --libs libmtp)"
    elif [[ -d /opt/homebrew/include ]] && [[ -f /opt/homebrew/lib/libmtp.dylib ]]; then
        cflags=(-I/opt/homebrew/include)
        ldflags=(-L/opt/homebrew/lib -lmtp)
    elif [[ -d /usr/local/include ]] && [[ -f /usr/local/lib/libmtp.dylib ]]; then
        cflags=(-I/usr/local/include)
        ldflags=(-L/usr/local/lib -lmtp)
    else
        cflags=()
        ldflags=(-lmtp)
    fi
    echo "Compiling tools/mtp_tool.c -> build/mtp_tool..."
    "$cc" -O2 -Wall "${cflags[@]}" "$repo_root/tools/mtp_tool.c" "${ldflags[@]}" -o "$mtp_tool"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    pkill -9 ptpcamerad 2>/dev/null || true
    sleep 0.2
fi

echo "Uploading usbdebug.koplugin via MTP -> /koreader/plugins/usbdebug.koplugin ..."
"$mtp_tool" put-dir "$plugin_dir" /koreader/plugins/usbdebug.koplugin
echo ""
echo "Done! Reopen KOReader on your Kindle — usbdebug.koplugin will start automatically."

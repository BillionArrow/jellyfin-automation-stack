#!/bin/bash

set -u
# Prevent concurrent execution
exec 200>"/tmp/zurg_sync.lock"
if ! flock -n 200; then
    echo "Another instance is already running. Exiting."
    exit 0
fi


# Define all your Zurg libraries
SOURCES=("/mnt/zurg/__all__")
INBOX="$HOME/jellyfin-server/jellyfin-media/inbox"
LEDGER="$HOME/jellyfin-server/jellyfin-media/.media_ledger.txt"
SKIP_HEALTH_CHECK=0

usage() {
    cat <<'USAGE'
Usage: zurg_sync.sh [--skip-health-check|--fast] [--help]

Options:
  --skip-health-check, --fast  Skip readiness/readability checks and sync immediately.
  -h, --help                   Show this help message.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --skip-health-check|--fast)
            SKIP_HEALTH_CHECK=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

# Add entry to ledger (prepend)
prepend_ledger_entry() {
    local entry="$1"
    if [ -s "$LEDGER" ]; then
        local -a existing_lines=()
        mapfile -t existing_lines < "$LEDGER"

        # Avoid duplicate ledger entries.
        if printf "%s\n" "${existing_lines[@]}" | grep -Fqx -- "$entry"; then
            return
        fi

        {
            printf "%s\n" "$entry"
            printf "%s\n" "${existing_lines[@]}"
        } | awk '!seen[$0]++' > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
    else
        printf "%s\n" "$entry" > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
    fi
}

# Return success only if all detected video files are readable from this host.
is_release_readable() {
    local source_path="$1"
    local file
    local checked=0

    while IFS= read -r -d '' file; do
        checked=1
        if ! head -c 1 "$file" >/dev/null 2>&1; then
            echo "Unreadable media file (I/O): $file"
            return 1
        fi
    done < <(find "$source_path" \( -type f -o -type l \) \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.ts" -o -iname "*.wmv" \) -print0)

    # If no video files were discovered, treat as not-ready.
    [ "$checked" -eq 1 ] || return 1
    return 0
}


# Ensure Inbox and Ledger exist
mkdir -p "$INBOX"
touch "$LEDGER"

# Loop through every library category
for dir in "${SOURCES[@]}"; do
    if [ -d "$dir" ]; then
        # 1. Take all titles in the directory
        # 2. Take all titles in the ledger (strip [UNREADABLE] prefix automatically for the compare so we skip them)
        # 3. Find exactly what is in the directory but missing from the ledger
        mapfile -t missing_items < <(LC_ALL=C comm -23 <(ls -A1 "$dir" | LC_ALL=C sort) <(sed 's/^\[UNREADABLE\] //' "$LEDGER" | tr -d '\r' | LC_ALL=C sort -u))

        for folder_name in "${missing_items[@]}"; do
            [ -n "$folder_name" ] || continue
            item="$dir/$folder_name"
            
            # Skip if the path doesn't exist (e.g., deleted mid-script)
            [ -e "$item" ] || continue

            echo "[DEBUG] Inspecting new/missing item: $folder_name"

            # --- THE ZURG GUARD ---
            if [ "$SKIP_HEALTH_CHECK" -eq 1 ]; then
                echo "[DEBUG] -> --skip-health-check enabled; syncing immediately: $folder_name"
            else
                # Check if Zurg has actually populated the video file yet.
                video_count=$(find "$item" \( -type f -o -type l \) \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.ts" -o -iname "*.wmv" \) 2>/dev/null | wc -l)

                if [ "$video_count" -eq 0 ]; then
                    echo "[DEBUG] -> Zurg has not populated the video file yet for: $folder_name. Will recheck on next run."
                    continue
                fi

                # Avoid importing releases whose media cannot be read yet (common rclone/zurg I/O transient).
                if ! is_release_readable "$item" >/dev/null; then
                    echo "[DEBUG] -> Files are unreadable. Marking as [UNREADABLE] to skip next run."
                    prepend_ledger_entry "[UNREADABLE] $folder_name"
                    continue
                fi
            fi
            # -----------------------

            echo "New drop detected and verified: $folder_name"
            
            # 1. Symlink it to the Inbox
            cp -rns "$item" "$INBOX/" 2>/dev/null || true
            
            # 2. Add it to the ledger (prepend).
            prepend_ledger_entry "$folder_name"
        done
    fi
done

echo "Sync complete!"
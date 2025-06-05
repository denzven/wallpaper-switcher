#!/usr/bin/env bash
#
# wallpaper_switcher.sh
#
# A refactored script to:
#   1. Apply pywal theme (and update cache), suppressing remote-control warnings
#   2. Reload Waybar using SIGUSR2 so it picks up new colors
#   3. Restart Dunst so it picks up new theme
#   4. Change the wallpaper with swww using a 'grow' transition:
#        • Queries cursor X/Y via `hyprctl cursorpos`
#        • Finds the monitor the cursor is on via `hyprctl monitors -j`
#        • Computes (REL_X, REL_Y) with Y inverted: REL_Y = monitor.height - (cursor_y - monitor.y)
#        • If any step fails, falls back to "center"
#   5. (Optional) Loop every INTERVAL minutes, picking a random image from WALLPAPER_DIR
#   6. Log each step, and optionally send a notification
#
# Usage:
#   # Single run:
#   ~/.local/bin/wallpaper_switcher.sh
#
#   # Daemon mode (loops forever every INTERVAL minutes):
#   ~/.local/bin/wallpaper_switcher.sh --daemon
#
#   # Override defaults:
#   ~/.local/bin/wallpaper_switcher.sh --daemon --interval 10 --wallpaper-dir ~/Pictures/Wallpapers
#
# Requires:
#   - bash (v4+)
#   - swww (supports `--transition-type grow --transition-pos X,Y` or "center" fallback)
#   - pywal (wal)
#   - waybar (listens for SIGUSR2)
#   - dunst
#   - hyprctl (Hyprland CLI)
#   - jq (to parse JSON from hyprctl monitors)
#   - notify-send (optional notifications)
#
# Configuration (defaults; override via CLI flags):
########################################
# Default wallpaper directory (absolute path):
WALLPAPER_DIR="${HOME}/wallpapers"

# Default log file:
LOG_FILE="${HOME}/.cache/wallpaper_switcher.log"

# Default interval (minutes) when running in --daemon mode:
INTERVAL=15

# Enable desktop notifications? (true/false)
ENABLE_NOTIFICATIONS=true
########################################

# =============================================================================
# Helper: print usage message
# =============================================================================
print_usage() {
    cat <<EOF
Usage: ${0##*/} [--daemon] [--interval MINUTES] [--wallpaper-dir DIR] [--no-notify] [--help]

Options:
  --daemon                   Run in infinite loop, changing wallpaper every \$INTERVAL minutes.
  --interval MINUTES         Interval (in minutes) between wallpaper changes in --daemon mode. Default: \$INTERVAL
  --wallpaper-dir DIR        Directory containing wallpapers (JPEG/PNG). Default: \$WALLPAPER_DIR
  --no-notify                Disable desktop notifications (notify-send).
  --help                     Show this help message and exit.

If not run with --daemon, this script performs a single cycle:
  1. Apply Pywal (wal -q -n -i)
  2. Reload Waybar (SIGUSR2)
  3. Restart Dunst
  4. Change wallpaper with swww (grow transition from cursor on Hyprland, Y inverted; fallback to center)
EOF
}

# =============================================================================
# Helper: log messages (both to stdout and to \$LOG_FILE, with timestamp)
# =============================================================================
log_message() {
    local msg="$1"
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "[${now}] ${msg}" | tee -a "${LOG_FILE}"
}

# =============================================================================
# Helper: send desktop notification (if enabled)
# =============================================================================
notify_user() {
    if [[ "${ENABLE_NOTIFICATIONS}" == true ]]; then
        local summary="$1"
        local body="$2"
        command -v notify-send &> /dev/null && notify-send --app-name="WallpaperSwitcher" "${summary}" "${body}"
    fi
}

# =============================================================================
# Function: apply_pywal_and_cache
#   - Runs `wal` with -q (quiet) and -n (no‐remote) so that “Remote control is disabled”
#     does not appear; updates ~/.cache/wal/colors.json and Xresources.
#   - Exits nonzero on failure.
# =============================================================================
apply_pywal_and_cache() {
    local image_path="$1"

    if [[ ! -f "${image_path}" ]]; then
        log_message "ERROR: Wallpaper '${image_path}' not found."
        return 1
    fi

    # -q = quiet, -n = --not-remote (suppress “Remote control is disabled”), -i <image>
    wal -q -n -i "${image_path}"
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: pywal failed to apply colors for '${image_path}'."
        return 1
    fi

    log_message "Pywal applied for '${image_path}'."
    return 0
}

# =============================================================================
# Function: reload_waybar
#   - Sends SIGUSR2 to all waybar processes so they reload their config/colors
#   - Exits nonzero on failure
# =============================================================================
reload_waybar() {
    if pgrep -x "waybar" &> /dev/null; then
        pkill -USR2 waybar
        if [[ $? -ne 0 ]]; then
            log_message "ERROR: Failed to send SIGUSR2 to waybar."
            return 1
        else
            log_message "Sent SIGUSR2 to waybar (reload requested)."
            return 0
        fi
    else
        log_message "WARNING: waybar not running; skipping reload."
        return 0
    fi
}

# =============================================================================
# Function: inject_dunst_colors
#   - Sources "~/.cache/wal/colors.sh" to load Pywal variables:
#       color0…color15, background, foreground, etc.
#   - Uses sed to replace Dunst settings in ~/.config/dunst/dunstrc,
#     exactly as in the original file.
#   - Sections modified:
#       • [global] (separator_color, frame_color, frame_color_low,
#                   frame_color_normal, frame_color_critical)
#       • [urgency_low]     (background, foreground, frame_color)
#       • [urgency_normal]  (background, foreground, frame_color)
#       • [urgency_critical] (background, foreground, frame_color)
#   - Logs successes and warnings via log_message.
#   - Returns 0 on success (or if colors.sh/dunstrc is missing), nonzero on error.
# =============================================================================
inject_dunst_colors() {
    # Path to the Pywal-generated shell file (defines color0…color15, background, foreground, etc.)
    local wal_sh="${HOME}/.cache/wal/colors.sh"
    # Path to your Dunst configuration file
    local dunstrc="${HOME}/.config/dunst/dunstrc"

    # 1) Source colors.sh if it exists; otherwise skip injection
    if [[ -f "${wal_sh}" ]]; then
        source "${wal_sh}"
        log_message "Sourced Pywal colors from ${wal_sh}."
    else
        log_message "WARNING: ${wal_sh} not found; skipping Dunst injection."
        return 0
    fi

    # 2) Ensure the directory for dunstrc exists, and create the file if needed
    mkdir -p "$(dirname "${dunstrc}")"
    [[ -f "${dunstrc}" ]] || touch "${dunstrc}"

    # 3) Replace in [global] section
    #    - separator_color → "${color1}"
    #    - frame_color     → "${color1}"
    #    - frame_color_low → "${color1}"
    #    - frame_color_normal → "${color4}"
    #    - frame_color_critical → "${color5}"
    sed -i \
        -e "s|^\s*separator_color\s*=.*|separator_color = \"${color1}\"|" \
        -e "s|^\s*frame_color\s*=.*|frame_color = \"${color1}\"|" \
        -e "s|^\s*frame_color_low\s*=.*|frame_color_low = \"${color1}\"|" \
        -e "s|^\s*frame_color_normal\s*=.*|frame_color_normal = \"${color4}\"|" \
        -e "s|^\s*frame_color_critical\s*=.*|frame_color_critical = \"${color5}\"|" \
        "${dunstrc}"

    # 4) Replace in [urgency_low] section
    #    - background → "${background}"
    #    - foreground → "${foreground}"
    #    - frame_color → "${color1}"
    sed -i \
        -e "/^\[urgency_low\]/, /^\[/ { \
               s|^\s*background\s*=.*|background = \"${background}\"|; \
               s|^\s*foreground\s*=.*|foreground = \"${foreground}\"|; \
               s|^\s*frame_color\s*=.*|frame_color = \"${color1}\"| \
           }" \
        "${dunstrc}"

    # 5) Replace in [urgency_normal] section
    #    - background → "${background}"
    #    - foreground → "${foreground}"
    #    - frame_color → "${color1}"
    sed -i \
        -e "/^\[urgency_normal\]/, /^\[/ { \
               s|^\s*background\s*=.*|background = \"${background}\"|; \
               s|^\s*foreground\s*=.*|foreground = \"${foreground}\"|; \
               s|^\s*frame_color\s*=.*|frame_color = \"${color1}\"| \
           }" \
        "${dunstrc}"

    # 6) Replace in [urgency_critical] section
    #    - background → "${color1}"
    #    - foreground → "${foreground}"
    #    - frame_color → "${color5}"
    sed -i \
        -e "/^\[urgency_critical\]/, /^\[/ { \
               s|^\s*background\s*=.*|background = \"${color1}\"|; \
               s|^\s*foreground\s*=.*|foreground = \"${foreground}\"|; \
               s|^\s*frame_color\s*=.*|frame_color = \"${color5}\"| \
           }" \
        "${dunstrc}"

    log_message "Injected Dunst colors from ${wal_sh} into ${dunstrc}."
    return 0
}


# =============================================================================
# Function: restart_dunst
#   - Kills any existing dunst and starts a new one
#   - Exits nonzero on failure
# =============================================================================
restart_dunst() {
    if pgrep -x "dunst" &> /dev/null; then
        pkill dunst
        sleep 0.2
    fi

    dunst & disown
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: Failed to start dunst."
        return 1
    fi

    log_message "Dunst restarted."
    return 0
}

# =============================================================================
# Function: get_cursor_xy_inverted
#   - Uses `hyprctl cursorpos` to get X and Y (rounded to integers).
#   - Uses `hyprctl monitors -j` and jq to find the monitor whose
#     geometry contains the cursor.
#   - Computes:
#       REL_X = cursor_x - monitor.x
#       REL_Y = monitor.height - (cursor_y - monitor.y)
#   - Echoes "REL_X,REL_Y". If anything fails (no hyprctl/jq or no match),
#     returns nonzero.
#
#   Hyprland’s JSON output for monitors (example):
#     [
#       {
#         "name": "eDP-1",
#         "model": "...",
#         "x": 0,
#         "y": 0,
#         "width": 1920,
#         "height": 1080,
#         ...
#       },
#       {
#         "name": "HDMI-A-1",
#         "x": 1920,
#         "y": 0,
#         "width": 1920,
#         "height": 1080,
#         ...
#       }
#     ]
#
#   To filter for the monitor under the cursor:
#     .[] | select(
#       (.x <= Xpos and (x + width) > Xpos) and
#       (.y <= Ypos and (y + height) > Ypos)
#     )
#   Then compute [ (Xpos - .x), ( .height - (Ypos - .y) ) ].
#
#   This ensures we “flip” the Y-axis so that (0,0) is bottom-left, as swww expects.
#   
#   
# =============================================================================
get_cursor_xy_inverted() {
    # Ensure hyprctl and jq are available
    if ! command -v hyprctl &> /dev/null || ! command -v jq &> /dev/null; then
        return 1
    fi

    # 1) Get global cursor position, e.g. "1234, 567"
    local raw_pos
    raw_pos=$(hyprctl cursorpos 2>/dev/null)
    if [[ -z "${raw_pos}" ]]; then
        return 1
    fi

    # 2) Parse X and Y (floating point), round to integers
    #    hyprctl cursorpos prints something like "1234.000000, 567.000000"
    local CURSOR_X CURSOR_Y
    read CURSOR_X CURSOR_Y <<< $(printf "%s" "${raw_pos}" | awk -F', ' '{ printf("%.0f %.0f", $1, $2); }')

    # 3) Query monitors JSON (array), find the one containing the cursor,
    #    then compute REL_X and REL_Y_inverted. Output as two numbers.
    local rel_sh
    rel_sh=$(
      hyprctl monitors -j 2>/dev/null \
        | jq -r --arg x "${CURSOR_X}" --arg y "${CURSOR_Y}" '
          .[] 
          | select(
              (.x <= ($x|tonumber)) and ((.x + .width) > ($x|tonumber)) and
              (.y <= ($y|tonumber)) and ((.y + .height) > ($y|tonumber))
            )
          | [ 
              ($x|tonumber) - .x, 
              .height - ( ($y|tonumber) - .y ) 
            ]
          | "\(.[0]) \(.[1])"
        ' 2>/dev/null
    )
    if [[ -z "${rel_sh}" ]]; then
        # No monitor match or jq failed
        return 1
    fi

    # 4) Split into REL_X and REL_Y
    local REL_X REL_Y
    read REL_X REL_Y <<< "${rel_sh}"

    # 5) Ensure they are integers
    REL_X=$(( REL_X / 1 ))
    REL_Y=$(( REL_Y / 1 ))

    # Echo as "X,Y"
    printf "%d,%d" "${REL_X}" "${REL_Y}"
    return 0
}

# =============================================================================
# Function: change_wallpaper_swww
#   - Attempts to set the wallpaper via `swww img <image>` using a "grow" transition.
#       1. Tries `--transition-pos REL_X,REL_Y` (from get_cursor_xy_inverted). 
#          If that succeeds, logs and returns 0.
#       2. Otherwise, logs a WARNING and retries `--transition-pos center`. 
#   - Exits nonzero only if both attempts fail.
# =============================================================================
change_wallpaper_swww() {
    local image_path="$1"

    if [[ ! -f "${image_path}" ]]; then
        log_message "ERROR: Wallpaper '${image_path}' not found."
        return 1
    fi

    # 1) Try from cursor (inverted Y)
    local pos
    if pos=$(get_cursor_xy_inverted); then
        swww img "${image_path}" \
            --transition-type grow \
            --transition-pos "${pos}" \
            --transition-step 90 \
            --transition-duration 2.0
        if [[ $? -eq 0 ]]; then
            log_message "Wallpaper set via swww from cursor (inverted Y = ${pos}): '${image_path}'."
            return 0
        else
            log_message "WARNING: swww failed with --transition-pos ${pos}. Falling back to center."
        fi
    else
        log_message "WARNING: Could not detect cursor/monitor. Falling back to center."
    fi

    # 2) Fallback to "center"
    swww img "${image_path}" \
        --transition-type grow \
        --transition-pos center \
        --transition-step 90 \
        --transition-duration 1.0
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: swww failed to set wallpaper '${image_path}' even with 'center'."
        return 1
    else
        log_message "Wallpaper set via swww from center (fallback): '${image_path}'."
        return 0
    fi
}

# =============================================================================
# Function: pick_random_wallpaper
#   - Chooses a random image file (jpg/png) from \$WALLPAPER_DIR
#   - Prints the selected path to stdout
#   - Returns nonzero if no images are found
# =============================================================================
pick_random_wallpaper() {
    local dir="$1"
    mapfile -t files < <(find "${dir}" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \))
    if [[ ${#files[@]} -eq 0 ]]; then
        return 1
    fi

    local idx=$(( RANDOM % ${#files[@]} ))
    printf "%s\n" "${files[$idx]}"
    return 0
}

# =============================================================================
# Function: do_one_cycle
#   - Performs one full cycle:
#       1. pick a random wallpaper
#       2. apply pywal (with -n)
#       3. reload waybar (SIGUSR2)
#       4. restart dunst
#       5. set wallpaper via swww (cursor→center fallback)
#       6. send desktop notification (optional)
#   - Returns 0 on overall success, nonzero if any step fails critically
# =============================================================================
do_one_cycle() {
    # 1) Pick a random wallpaper
    local selected
    if ! selected="$(pick_random_wallpaper "${WALLPAPER_DIR}")"; then
        log_message "ERROR: No wallpapers found in '${WALLPAPER_DIR}'."
        return 1
    fi
    log_message "Selected random wallpaper: ${selected}"

    # 2) Apply pywal (theme/colors), suppress “Remote control is disabled”
    apply_pywal_and_cache "${selected}"
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: Skipping this cycle due to Pywal failure."
        return 1
    fi

    # 3) Reload Waybar (SIGUSR2)
    reload_waybar
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: Waybar reload failed. Continuing anyway."
    fi

    # 4) Restart Dunst
    inject_dunst_colors
    restart_dunst
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: Dunst restart failed. Continuing anyway."
    fi

    # 5) Finally, change wallpaper with swww (cursor→center fallback)
    change_wallpaper_swww "${selected}"
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: swww wallpaper change failed."
        return 1
    fi

    # 6) Send a notification (optional)
    notify_user "Wallpaper Changed" "New wallpaper: $(basename "${selected}")"
    return 0
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Parse command-line args
MODE="single"  # default: run one cycle
while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon)
            MODE="daemon"
            shift
            ;;
        --interval)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                INTERVAL="$2"
                shift 2
            else
                echo "ERROR: --interval requires a positive integer argument." >&2
                exit 1
            fi
            ;;
        --wallpaper-dir)
            if [[ -n "$2" ]]; then
                WALLPAPER_DIR="$2"
                shift 2
            else
                echo "ERROR: --wallpaper-dir requires a directory path." >&2
                exit 1
            fi
            ;;
        --no-notify)
            ENABLE_NOTIFICATIONS=false
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            print_usage
            exit 1
            ;;
    esac
done

# Ensure log directory exists
mkdir -p "$(dirname "${LOG_FILE}")"

# Check that WALLPAPER_DIR exists and is a directory
if [[ ! -d "${WALLPAPER_DIR}" ]]; then
    echo "ERROR: Wallpaper directory '${WALLPAPER_DIR}' not found." >&2
    exit 1
fi

# Run one cycle immediately (for both modes)
log_message "=== Starting wallpaper change cycle ==="
if ! do_one_cycle; then
    log_message "Cycle FAILED."
else
    log_message "Cycle completed successfully."
fi

# If in daemon mode, loop forever
if [[ "${MODE}" == "daemon" ]]; then
    log_message "Entering daemon mode: will change every ${INTERVAL} minute(s)."
    while true; do
        log_message "Sleeping for ${INTERVAL} minute(s)…"
        sleep "$(( INTERVAL * 60 ))"
        log_message "=== Starting wallpaper change cycle ==="
        if ! do_one_cycle; then
            log_message "Cycle FAILED."
        else
            log_message "Cycle completed successfully."
        fi
    done
fi

exit 0


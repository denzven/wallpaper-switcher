**Wallpaper Switcher**
A modular Bash script to automatically change your wallpaper on Hyprland/Sway using `swww`, apply a Pywal theme, and update Waybar and Dunst with matching colors. Includes a “daemon” mode for timed rotation, logging, and optional desktop notifications.

---

## Table of Contents

* [Features](#features)
* [Requirements](#requirements)
* [Installation](#installation)
* [Configuration](#configuration)
* [Usage](#usage)
* [Script Breakdown](#script-breakdown)
* [Screenshots](#screenshots)
* [License](#license)

---

## Features

1. **Random Wallpaper Selection**
   • Chooses a random image (JPEG/PNG) from a specified directory.
2. **Pywal Integration**
   • Runs `wal -q -n -i <image>` to generate a color palette and apply it system-wide.
   • Sources Pywal’s `colors.sh` to inject variables into Dunst.
3. **Waybar Reload (SIGUSR2)**
   • Sends `SIGUSR2` to all running Waybar instances so they immediately reload their configuration and new colors.
4. **Dunst Color Injection & Restart**
   • Sources `~/.cache/wal/colors.sh`, extracts `background`, `foreground`, `color1`, `color4`, `color5`.
   • Replaces relevant keys in `~/.config/dunst/dunstrc` (global and urgency sections).
   • Kills and restarts Dunst so it picks up the updated color scheme.
5. **Cursor-Based `swww` Transition**
   • Queries Hyprland’s `hyprctl cursorpos` to get raw `X,Y` coordinates.
   • Finds which monitor the cursor is on via `hyprctl monitors -j`, then computes a bottom-left–inverted `Y` for `swww`.
   • Invokes `swww img <image> --transition-type grow --transition-pos <X,Y>` to create a smooth “grow” animation starting from the pointer location.
   • Falls back to `--transition-pos center` if detection fails.
6. **Daemon/Timer Mode**
   • Run once for an immediate change, or use `--daemon` to loop every N minutes (default 15).
   • Sleep between cycles to reduce CPU/HDD usage on slower machines.
7. **Logging & Notifications**
   • Appends progress and errors to `~/.cache/wallpaper_switcher.log` with timestamps.
   • Optionally sends desktop notifications via `notify-send` (can be disabled with `--no-notify`).

---

## Requirements

* **Bash 4+**
* **Hyprland** (or Sway, with slight modifications)

  * `hyprctl` must be in your `$PATH`
* **Pywal** (`wal`)

  * Generates `~/.cache/wal/colors.*` files
* **swww** (Simple Wayland Wallpaper)

  * With support for `--transition-type grow` and `--transition-pos X,Y`
* **Waybar**

  * Listens for `SIGUSR2` to reload its configuration
* **Dunst**

  * Configured via `~/.config/dunst/dunstrc`
* **jq**

  * Parses JSON output from `hyprctl`
* **notify-send** (from `libnotify`)

  * For optional desktop notifications

**Optional (if running on Sway)**

* Replace the `get_cursor_xy_inverted` function with one that uses `swaymsg -t get_cursor_position` and `swaymsg -t get_outputs -r`.

---

## Installation

1. **Clone or download** this repository to your local machine:

   ```bash
   git clone https://github.com/<your-username>/wallpaper-switcher.git
   cd wallpaper-switcher
   ```

2. **Make the script executable**:

   ```bash
   chmod +x wallpaper_switcher.sh
   ```

   or, if you place it in `~/.local/bin/`:

   ```bash
   install -Dm755 wallpaper_switcher.sh ~/.local/bin/wallpaper_switcher.sh
   ```

3. **Install required packages** (example for Arch Linux):

   ```bash
   sudo pacman -S hyprland hyprland-docs pywal swww waybar dunst jq libnotify
   ```

4. **Ensure your wallpaper folder exists** (default: `~/Pictures/Wallpapers`):

   ```bash
   mkdir -p ~/Pictures/Wallpapers
   ```

5. **Populate** that folder with your `.jpg`/`.png` images.

---

## Configuration

All default settings are at the top of **`wallpaper_switcher.sh`**:

```bash
# Default wallpaper directory:
WALLPAPER_DIR="${HOME}/Pictures/Wallpapers"

# Default log file:
LOG_FILE="${HOME}/.cache/wallpaper_switcher.log"

# Default interval (minutes) in daemon mode:
INTERVAL=15

# Enable desktop notifications? (true/false)
ENABLE_NOTIFICATIONS=true
```

* To change the wallpaper directory, modify `WALLPAPER_DIR` or use `--wallpaper-dir <DIR>`.
* To disable notifications, use `--no-notify`.
* To change the daemon interval, modify `INTERVAL` or use `--interval <MINUTES>`.

### Dunst Configuration

Your **`~/.config/dunst/dunstrc`** should have placeholders exactly as shown below:

```ini
[global]
# Example Dunst global settings
# Customize these as needed; the script will replace them
separator_color     = "%color1%"
frame_color         = "%color1%"
frame_color_low     = "%color1%"
frame_color_normal  = "%color4%"
frame_color_critical= "%color5%"

[urgency_low]
background = "%background%"
foreground = "%foreground%"
frame_color= "%color1%"

[urgency_normal]
background = "%background%"
foreground = "%foreground%"
frame_color= "%color1%"

[urgency_critical]
background = "%color1%"
foreground = "%foreground%"
frame_color= "%color5%"
```

When Pywal runs, it updates `~/.cache/wal/colors.sh`, which defines:

```bash
color0="#…"
color1="#…"
…
color4="#…"
color5="#…"
background="#…"
foreground="#…"
# (and so on)
```

The `inject_dunst_colors` function:

* Sources that file (`source "$HOME/.cache/wal/colors.sh"`).
* Runs a series of `sed -i` commands to replace the `%…%` placeholders in your `dunstrc`.
* Logs which values were injected.

---

## Usage

```bash
# Single run (change wallpaper once)
./wallpaper_switcher.sh

# Run in daemon mode (loop indefinitely every 15 minutes)
./wallpaper_switcher.sh --daemon

# Override defaults:
./wallpaper_switcher.sh \
    --daemon \
    --interval 10 \
    --wallpaper-dir ~/Wallpapers \
    --no-notify
```

**Command-Line Options**

```
--daemon              Run in an infinite loop every $INTERVAL minutes.
--interval MINUTES    Interval (in minutes) for daemon mode. Default: 15
--wallpaper-dir DIR   Directory containing wallpapers. Default: ~/Pictures/Wallpapers
--no-notify           Disable desktop notifications (notify-send).
-h, --help            Show this help message and exit.
```

**Cron Example**
If you’d rather use cron instead of long-lived daemon:

```cron
# Edit your crontab (crontab -e) and add:
*/15 * * * * ~/path/to/wallpaper_switcher.sh >/dev/null 2>&1
```

**Systemd User Service**
Create `~/.config/systemd/user/wallpaper_switcher.service`:

```ini
[Unit]
Description=Wallpaper Switcher (Pywal + swww + Waybar + Dunst)

[Service]
ExecStart=%h/.local/bin/wallpaper_switcher.sh --daemon
Restart=on-failure

[Install]
WantedBy=default.target
```

Then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now wallpaper_switcher.service
```

---

## Script Breakdown

Below is a high-level summary of each part of `wallpaper_switcher.sh`:

1. **Shebang & Configuration**

   ```bash
   #!/usr/bin/env bash

   WALLPAPER_DIR="${HOME}/Pictures/Wallpapers"
   LOG_FILE="${HOME}/.cache/wallpaper_switcher.log"
   INTERVAL=15
   ENABLE_NOTIFICATIONS=true
   ```

   * Sets the default wallpaper folder, log path, timer interval, and whether notifications are enabled.

2. **Helper Functions**

   * `log_message()`: Logs messages with a timestamp to both stdout and `$LOG_FILE`.
   * `notify_user()`: Sends a desktop notification via `notify-send` (if enabled).

3. **`apply_pywal_and_cache(image)`**

   ```bash
   wal -q -n -i "${image}"
   ```

   * Runs Pywal in quiet, no-remote mode on the specified image to generate color files (`colors.sh`, `colors.json`, `colors-dunst`, etc.).
   * Logs success or failure.

4. **`reload_waybar()`**

   ```bash
   pkill -USR2 waybar
   ```

   * Sends `SIGUSR2` to all running `waybar` processes, causing Waybar to immediately reload its config (including any new colors from Pywal).

5. **`inject_dunst_colors()`**

   * **Sources** `$HOME/.cache/wal/colors.sh` to populate Bash variables:

     ```bash
     source "$HOME/.cache/wal/colors.sh"
     ```
   * Uses a series of `sed -i` commands to replace the following in `~/.config/dunst/dunstrc`:

     ```bash
     # [global] replacements:
     separator_color     → "${color1}"
     frame_color         → "${color1}"
     frame_color_low     → "${color1}"
     frame_color_normal  → "${color4}"
     frame_color_critical→ "${color5}"

     # [urgency_low], [urgency_normal]:
     background → "${background}"
     foreground → "${foreground}"
     frame_color→ "${color1}"

     # [urgency_critical]:
     background → "${color1}"
     foreground → "${foreground}"
     frame_color→ "${color5}"
     ```
   * Logs any missing files or errors.

6. **`restart_dunst()`**

   ```bash
   pkill dunst
   sleep 0.2
   dunst & disown
   ```

   * Kills any running Dunst instance, waits briefly, and launches a fresh one so it reads the updated config.

7. **`get_cursor_xy_inverted()`**

   * Runs:

     ```bash
     raw_pos=$(hyprctl cursorpos)
     ```

     which outputs something like `1234.000000, 567.000000`.
   * Rounds to integers (`1234`, `567`).
   * Queries `hyprctl monitors -j` to get JSON for all outputs.
   * Uses `jq` to find the monitor with:

     ```
     .x <= cursor_x < .x + .width
     .y <= cursor_y < .y + .height
     ```
   * Computes:

     ```
     REL_X = cursor_x − monitor.x
     REL_Y = monitor.height − (cursor_y − monitor.y)
     ```
   * Echoes as `REL_X,REL_Y`.
   * If anything fails (missing `hyprctl`, no monitor match, missing `jq`), returns nonzero.

8. **`change_wallpaper_swww(image)`**

   ```bash
   if pos=$(get_cursor_xy_inverted); then
       swww img "${image}" \
           --transition-type grow \
           --transition-pos "${pos}" \
           --transition-step 90 \
           --transition-duration 1.0
       ...
   else
       swww img "${image}" \
           --transition-type grow \
           --transition-pos center \
           --transition-step 90 \
           --transition-duration 1.0
       ...
   fi
   ```

   * Attempts a “grow” transition from `(X,Y)` under the cursor.
   * If that fails, falls back to a center-based grow.
   * Logs success or warning.

9. **`pick_random_wallpaper(dir)`**

   * Finds all `.jpg`, `.jpeg`, `.png` files in `$dir` using `find`.
   * Uses `$RANDOM` to pick one at random.
   * Prints its path to stdout.

10. **`do_one_cycle()`**

    1. Pick a random wallpaper.
    2. `apply_pywal_and_cache` on that wallpaper.

       * If it fails, abort this cycle.
    3. `reload_waybar`.
    4. `inject_dunst_colors`.
    5. `restart_dunst`.
    6. `change_wallpaper_swww`.

       * If it fails, abort this cycle.
    7. `notify_user "Wallpaper Changed" "New: $(basename "$wallpaper")"`.

       * Only if `ENABLE_NOTIFICATIONS=true`.

11. **Main Script Flow**

    * Parses CLI arguments (`--daemon`, `--interval`, `--wallpaper-dir`, `--no-notify`, `--help`).
    * Ensures `$WALLPAPER_DIR` exists.
    * Logs “Starting wallpaper change cycle” and invokes `do_one_cycle`.
    * If `--daemon` was passed, enters an infinite `while true` loop, sleeping for `$INTERVAL * 60` seconds between cycles.

---

## Screenshots

*(Replace each `<placeholder>` with an actual screenshot when you publish to GitHub.)*

1. **Waybar with Pywal colors + New Wallpaper**
   ![Waybar Reloaded](path/to/waybar_screenshot.png)

2. **Dunst Notification Sample**
   ![Dunst Notification](path/to/dunst_notification.png)

3. **Cursor-based Grow Transition in Action**
   ![swww Grow Animation](path/to/swww_grow_screenshot.gif)

---

## License

This project is released under the **MIT License**. See [LICENSE](./LICENSE) for details.

---

> **Enjoy smooth, Pywal-themed wallpapers**! Feel free to open issues or pull requests if you find improvements or run into bugs.

made with love by denzven 💜 and ChatGPT 🤖

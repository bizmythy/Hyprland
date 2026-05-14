#!/usr/bin/env bash
set -euo pipefail

# Debug harness for PR #14447 / Lua hl.monitor({ disabled = false }) behavior.
#
# What it does:
#   1. Performs a fresh debug build using the repository Makefile.
#   2. Starts the freshly-built Hyprland nested on your current Wayland session
#      (wayland backend, not headless, so you can see the output windows).
#   3. Uses a temporary Lua config with two named test outputs:
#        - PRTEST-1 starts enabled
#        - PRTEST-2 starts disabled
#   4. Binds ALT+1 and ALT+2 to toggle those monitor rules via Lua hl.monitor().
#      Re-enabling a disabled output calls hl.monitor({ disabled = false }), which
#      directly exercises the code path changed by PR #14447.
#
# Expected with the PR/fix: pressing ALT+2 makes PRTEST-2 appear; pressing it
# again hides it. ALT+1 should similarly hide/show PRTEST-1.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "This test needs to run from an existing Wayland session so nested Hyprland is visible." >&2
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    echo "XDG_RUNTIME_DIR is not set." >&2
    exit 1
fi

printf '\n==> Fresh debug build (repo guidance: make clear && make debug)\n'
make clear
make debug

TMPDIR="$(mktemp -d --tmpdir hyprland-lua-monitor-toggle.XXXXXX)"
CONFIG="$TMPDIR/hyprland-pr14447.lua"
LOG="$TMPDIR/hyprland.log"

cleanup() {
    set +e
    if [[ -n "${HYPR_PID:-}" ]] && kill -0 "$HYPR_PID" 2>/dev/null; then
        if [[ -n "${TEST_HIS:-}" ]]; then
            ./build/hyprctl/hyprctl -i "$TEST_HIS" dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || true
        fi
        sleep 1
        kill "$HYPR_PID" >/dev/null 2>&1 || true
        wait "$HYPR_PID" 2>/dev/null || true
    fi
    echo "Logs/config kept in: $TMPDIR"
}
trap cleanup EXIT

cat >"$CONFIG" <<'LUA'
-- Minimal Lua config for testing PR #14447.
-- The important operation is changing an existing monitor rule from
-- disabled=true to disabled=false from Lua.

local mon1 = "PRTEST-1"
local mon2 = "PRTEST-2"
local mon1_enabled = true
local mon2_enabled = false

local function apply_monitor(name, enabled, x)
    print(string.format("setting %s enabled=%s", name, tostring(enabled)))
    hl.monitor({
        output = name,
        mode = "1280x720@60",
        position = x .. "x0",
        scale = 1,
        disabled = not enabled,
    })
end

-- Initial rules: monitor 1 enabled, monitor 2 disabled.
apply_monitor(mon1, mon1_enabled, 0)
apply_monitor(mon2, mon2_enabled, 1280)

hl.config({
    general = { gaps_in = 0, gaps_out = 0, border_size = 2 },
    decoration = { rounding = 0, shadow = { enabled = false }, blur = { enabled = false } },
    animations = { enabled = false },
    misc = { disable_hyprland_logo = true, force_default_wallpaper = 0 },
    input = { kb_layout = "us" },
    debug = { disable_logs = false },
})

hl.bind("ALT + 1", function()
    mon1_enabled = not mon1_enabled
    apply_monitor(mon1, mon1_enabled, 0)
    print("ALT+1 toggled " .. mon1 .. " -> enabled=" .. tostring(mon1_enabled))
end)

hl.bind("ALT + 2", function()
    mon2_enabled = not mon2_enabled
    apply_monitor(mon2, mon2_enabled, 1280)
    print("ALT+2 toggled " .. mon2 .. " -> enabled=" .. tostring(mon2_enabled))
end)

hl.bind("ALT + Q", hl.dsp.exit())
LUA

printf '\n==> Starting nested debug Hyprland with %s\n' "$CONFIG"
HYPRLAND_NO_CRASHREPORTER=1 ASAN_OPTIONS="log_path=$TMPDIR/asan.log" ./build/Hyprland -c "$CONFIG" >"$LOG" 2>&1 &
HYPR_PID=$!

printf '==> Waiting for hyprctl instance for PID %s\n' "$HYPR_PID"
TEST_HIS=""
for _ in {1..100}; do
    TEST_HIS="$(python3 - "$HYPR_PID" <<'PY' || true
import os, sys
pid = sys.argv[1]
runtime = os.environ.get("XDG_RUNTIME_DIR", "")
root = os.path.join(runtime, "hypr")
if not os.path.isdir(root):
    sys.exit(0)
for name in os.listdir(root):
    lock = os.path.join(root, name, "hyprland.lock")
    try:
        with open(lock) as f:
            lock_pid = f.readline().strip()
        if lock_pid == pid:
            print(name)
            break
    except OSError:
        pass
PY
)"
    [[ -n "$TEST_HIS" ]] && break
    if ! kill -0 "$HYPR_PID" 2>/dev/null; then
        echo "Hyprland exited early. Log follows:" >&2
        sed -n '1,220p' "$LOG" >&2 || true
        exit 1
    fi
    sleep 0.1
done

if [[ -z "$TEST_HIS" ]]; then
    echo "Timed out waiting for Hyprland instance. Log: $LOG" >&2
    exit 1
fi

printf '==> Nested Hyprland instance: %s\n' "$TEST_HIS"

printf '\n==> Creating two named Wayland test outputs\n'
./build/hyprctl/hyprctl -i "$TEST_HIS" output create wayland PRTEST-1 || true
./build/hyprctl/hyprctl -i "$TEST_HIS" output create wayland PRTEST-2 || true
sleep 1

printf '\n==> Initial monitor state (all monitors, including disabled)\n'
./build/hyprctl/hyprctl -i "$TEST_HIS" monitors all || true

cat <<EOF

Test is running.
  - You should see nested Hyprland output window(s), including PRTEST-1.
  - PRTEST-2 is intentionally disabled by the loaded Lua config.
  - Press Left Alt + 1 inside the nested Hyprland window to toggle PRTEST-1.
  - Press Left Alt + 2 inside the nested Hyprland window to toggle PRTEST-2.
  - Press Alt + Q inside nested Hyprland, or Ctrl+C here, to quit.

Useful from another terminal while it runs:
  ./build/hyprctl/hyprctl -i "$TEST_HIS" monitors all
  tail -f "$LOG"

If the review comment is correct / old behavior is present, the transition from
 disabled=true -> disabled=false will not actually re-enable the output. With PR
 #14447's commit, ALT+2 should enable PRTEST-2 without a full config reload.
EOF

wait "$HYPR_PID"

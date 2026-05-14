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
#      It also exposes a terminal-driven request file so you do not have to rely
#      on flaky nested-input capture to run the exact same Lua toggle code.
#      The toggle derives state from hl.get_monitor(name), like a real config that
#      reapplies enabled/disabled monitor profiles, instead of keeping separate
#      test-only state. Re-enabling a disabled output calls
#      hl.monitor({ disabled = false }), directly exercising PR #14447.
#
# Expected with the PR/fix: toggling PRTEST-1 disables it and leaves it disabled;
# toggling PRTEST-2 enables it; toggling the same output again flips it back.


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
BOOT_LOG="$TMPDIR/hyprland-boot.log"
LOG="$BOOT_LOG"
REQUEST="$TMPDIR/toggle-request"

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
local request_path = os.getenv("HYPR_MONITOR_TOGGLE_REQUEST")

local function apply_monitor(name, enabled, x)
    print(string.format("MONITOR_TEST apply %s enabled=%s", name, tostring(enabled)))
    hl.monitor({
        output = name,
        mode = "1280x720@60",
        position = x .. "x0",
        scale = 1,
        disabled = not enabled,
    })
end

local function is_enabled(name)
    -- Disabled outputs are not in hl.get_monitors()/hl.get_monitor(), so this
    -- mirrors profile-style config: if it is currently present, disabling it is
    -- the next toggle; if absent/disabled, apply a full enabled monitor spec.
    return hl.get_monitor(name) ~= nil
end

local function toggle_monitor(name, x)
    local currently_enabled = is_enabled(name)
    local next_enabled = not currently_enabled
    print(string.format("MONITOR_TEST toggle %s currently_enabled=%s next_enabled=%s", name, tostring(currently_enabled), tostring(next_enabled)))
    apply_monitor(name, next_enabled, x)
end

-- Initial rules: monitor 1 enabled, monitor 2 disabled.
apply_monitor(mon1, true, 0)
apply_monitor(mon2, false, 1280)

hl.config({
    general = { gaps_in = 0, gaps_out = 0, border_size = 2 },
    decoration = { rounding = 0, shadow = { enabled = false }, blur = { enabled = false } },
    animations = { enabled = false },
    misc = { disable_hyprland_logo = true, force_default_wallpaper = 0 },
    input = { kb_layout = "us" },
    debug = { disable_logs = false },
})

hl.bind("ALT + 1", function()
    print("MONITOR_TEST ALT+1 received")
    toggle_monitor(mon1, 0)
end)

hl.bind("ALT + 2", function()
    print("MONITOR_TEST ALT+2 received")
    toggle_monitor(mon2, 1280)
end)

hl.bind("ALT + Q", hl.dsp.exit())

hl.on("monitor.added", function(mon)
    print("MONITOR_TEST event added " .. tostring(mon))
end)

hl.on("monitor.removed", function(mon)
    print("MONITOR_TEST event removed " .. tostring(mon))
end)

hl.on("monitor.layout_changed", function()
    print("MONITOR_TEST event layout_changed")
end)

-- Terminal-driven control path. The shell writes a unique line ending in
-- " 1" or " 2" to this file. This avoids nested keyboard capture entirely
-- while still executing the same in-compositor Lua hl.monitor() code.
local last_request = ""
if request_path ~= nil then
    hl.timer(function()
        local f = io.open(request_path, "r")
        if f == nil then
            return
        end

        local request = f:read("*a") or ""
        f:close()

        if request == "" or request == last_request then
            return
        end

        last_request = request
        if request:match("1%s*$") then
            print("MONITOR_TEST terminal request 1 received")
            toggle_monitor(mon1, 0)
        elseif request:match("2%s*$") then
            print("MONITOR_TEST terminal request 2 received")
            toggle_monitor(mon2, 1280)
        end
    end, { timeout = 100, type = "repeat" })
end
LUA

printf '\n==> Starting nested debug Hyprland with %s\n' "$CONFIG"
: >"$REQUEST"
HYPR_MONITOR_TOGGLE_REQUEST="$REQUEST" HYPRLAND_NO_CRASHREPORTER=1 ASAN_OPTIONS="log_path=$TMPDIR/asan.log" ./build/Hyprland -c "$CONFIG" >"$BOOT_LOG" 2>&1 &
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
        sed -n '1,220p' "$BOOT_LOG" >&2 || true
        exit 1
    fi
    sleep 0.1
done

if [[ -z "$TEST_HIS" ]]; then
    echo "Timed out waiting for Hyprland instance. Log: $LOG" >&2
    exit 1
fi

printf '==> Nested Hyprland instance: %s\n' "$TEST_HIS"
SESSION_DIR="$XDG_RUNTIME_DIR/hypr/$TEST_HIS"
for _ in {1..50}; do
    if [[ -f "$SESSION_DIR/hyprlandd.log" ]]; then
        LOG="$SESSION_DIR/hyprlandd.log"
        break
    elif [[ -f "$SESSION_DIR/hyprland.log" ]]; then
        LOG="$SESSION_DIR/hyprland.log"
        break
    fi
    sleep 0.1
done
printf '==> Hyprland session log: %s\n' "$LOG"

printf '\n==> Creating two named Wayland test outputs\n'
./build/hyprctl/hyprctl -i "$TEST_HIS" output create wayland PRTEST-1 || true
./build/hyprctl/hyprctl -i "$TEST_HIS" output create wayland PRTEST-2 || true
sleep 1


print_monitor_state() {
    local monitors_text
    monitors_text="$(./build/hyprctl/hyprctl -i "$TEST_HIS" monitors all 2>/dev/null || true)"

    printf '\n==> Concise enabled/disabled summary\n'
    printf '%s\n' "$monitors_text" \
        | awk '/^Monitor / { mon=$2 } /^[[:space:]]+disabled:/ { printf "  %s disabled=%s\n", mon, $2 }' || true


    printf '\n==> Monitor state (all monitors, including disabled)\n'
    printf '%s\n' "$monitors_text"
    printf '\n==> Lua/test log lines\n'
    if [[ -f "$LOG" ]]; then
        grep -E 'MONITOR_TEST|Applying monitor rule|onDisconnect called for|Monitor .*disabled|requested to be enabled|layout_changed' "$LOG" | tail -n 100 || true
    else
        printf 'log file not found yet: %s\n' "$LOG"
    fi
}

print_monitor_state

cat <<EOF

Test is running.
  - WAYLAND-1 is the nested compositor's default output; leave it alone.
  - PRTEST-1 starts enabled; PRTEST-2 starts disabled.
  - For reliable testing, use THIS TERMINAL instead of captured nested input:
      1  toggle PRTEST-1 by running the Lua hl.monitor() code
      2  toggle PRTEST-2 by running the Lua hl.monitor() code
      m  print monitor state
      q  quit
  - The nested keybinds still exist too: Left Alt+1, Left Alt+2, Alt+Q.

Useful from another terminal while it runs:
  ./build/hyprctl/hyprctl -i "$TEST_HIS" monitors all
  tail -f "$LOG"

Important: this intentionally leaves the synthetic Wayland outputs connected and
uses only Lua hl.monitor({ disabled = ... }) to toggle them. If a host-side
nested output window remains visible after disabled=true, that is part of what
this test is meant to expose.
EOF

while kill -0 "$HYPR_PID" 2>/dev/null; do
    printf '\ncommand [1/2/m/q]> '
    if ! IFS= read -r -n 1 key; then
        break
    fi
    printf '\n'

    case "$key" in
        1|2)
            printf '%s %s\n' "$(date +%s%N)" "$key" >"$REQUEST"
            sleep 0.5
            print_monitor_state
            ;;
        m|M)
            print_monitor_state
            ;;
        q|Q)
            ./build/hyprctl/hyprctl -i "$TEST_HIS" dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || true
            break
            ;;
    esac
done

wait "$HYPR_PID"

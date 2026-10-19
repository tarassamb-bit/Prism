#!/bin/zsh
# Drives the installed Prism app through System Events. Needs Accessibility permission for the terminal
# (System Settings > Privacy & Security > Accessibility). Read-only except for moving between screens.
set -euo pipefail
app_path=${1:-$HOME/Applications/Prism.app}
[[ -d "$app_path" ]] || { echo "FAIL: $app_path not installed. Run scripts/package-app.sh and install it first."; exit 1; }
osascript -e "tell application \"$app_path\" to activate"
sleep 2
result=$(osascript <<'APPLESCRIPT'
on run
    tell application "System Events"
        if not (exists process "Prism") then return "FAIL: Prism is not running"
        tell process "Prism"
            set frontmost to true
            if (count of windows) is 0 then return "FAIL: no Prism window"
            set w to front window
            set allText to my labelsOf(w)
            if allText does not contain "Start creating" then return "FAIL: home screen is missing 'Start creating'"
            if allText does not contain "Projects" then return "FAIL: home screen is missing the Projects section"
            if allText does not contain "Settings" then return "FAIL: sidebar is missing Settings"
            click (first button of w whose description is "Settings" or name is "Settings")
            delay 1
            set settingsText to my labelsOf(front window)
            if settingsText does not contain "AI & Cloud" then return "FAIL: Settings did not open"
            click (first button of front window whose name is "Home" or description is "Home")
            delay 1
            if (my labelsOf(front window)) does not contain "Start creating" then return "FAIL: Home did not reopen"
            return "PASS: Prism opens to Home, shows Projects, and moves between Home and Settings"
        end tell
    end tell
end run

on labelsOf(w)
    set out to ""
    tell application "System Events"
        repeat with el in (entire contents of w)
            try
                set out to out & (name of el as text) & "|"
            end try
            try
                set out to out & (description of el as text) & "|"
            end try
        end repeat
    end tell
    return out
end labelsOf
APPLESCRIPT
)
echo "$result"
[[ "$result" == PASS* ]]

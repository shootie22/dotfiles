-- Hyprland (Lua config) -- https://wiki.hypr.land/Configuring/
-- Deployed by home-manager; edits here are overwritten on rebuild.

-- Monitors --------------------------------------------------------------------
hl.monitor({ output = "", mode = "2560x1440@180", position = "auto", scale = "1" })

-- Programs ------------------------------------------------------------------
local terminal    = "kitty --single-instance"
local fileManager = "uwsm app -- dolphin"
local browser     = "uwsm app -- librewolf"
local ipc         = "noctalia msg "

-- Environment -------------------------------------------------------------
hl.env("XCURSOR_THEME", "Vanilla-DMZ-AA")
hl.env("XCURSOR_SIZE", "24")
hl.env("QT_QPA_PLATFORMTHEME", "kde")   -- KDE platform theme -> Breeze Dark KColorScheme

-- Look & feel -----------------------------------------------------------
hl.config({
    general = {
        border_size = 1,
        gaps_in     = 4,
        gaps_out    = 8,
        col = {
            active_border   = "rgba(c4b3eeff)",   -- fallback; overridden by Noctalia below
            inactive_border = "rgba(3a3a3aff)",
        },
        layout = "dwindle",
    },

    decoration = {
        rounding = 0,
        shadow = { enabled = false },
        blur = {
            enabled  = true,
            size     = 4,
            passes   = 2,
            vibrancy = 0.15,
        },
    },

    animations = { enabled = true },
    dwindle    = { preserve_split = true },

    input = {
        kb_layout    = "us,dk",   -- toggle with SUPER + Space
        follow_mouse = 1,
        touchpad     = { natural_scroll = false },
    },

    misc = {
        disable_hyprland_logo   = true,
        force_default_wallpaper = 0,
        focus_on_activate       = true,   -- honour "activate me" requests (e.g. clicking a notification)
    },
})

-- Border colours from Noctalia's palette (regenerated + reloaded on theme change).
pcall(dofile, os.getenv("HOME") .. "/.config/hypr/noctalia-colors.lua")

-- Animations: snappy, ~2x the default speed ------------------------------
hl.curve("snappy", { type = "bezier", points = { {0.2, 1}, {0.25, 1} } })
hl.animation({ leaf = "global",     enabled = true, speed = 3,   bezier = "snappy" })
hl.animation({ leaf = "windows",    enabled = true, speed = 2.5, bezier = "snappy" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.5, bezier = "snappy" })

-- Noctalia (the shell is started by its systemd user service) --------------
hl.layer_rule({
    name         = "noctalia",
    match        = { namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$" },
    no_anim      = true,
    blur         = true,
    blur_popups  = true,
    ignore_alpha = 0.5,
})
hl.window_rule({
    name  = "noctalia-settings",
    match = { class = "dev.noctalia.Noctalia" },
    float = true,
    size  = { 1080, 920 },
})

-- Keybindings -------------------------------------------------------------
local mod = "SUPER"

-- Tapping Super alone sends KEY_F13 (via keyd tap/hold); holding it stays as the
-- modifier. Bound by keycode 191 because xkb's pc keymap gives F13 no keysym.
hl.bind("code:191", hl.dsp.exec_cmd(ipc .. "panel-toggle launcher"))

hl.bind(mod .. " + Q",      hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + E",      hl.dsp.exec_cmd(fileManager))
hl.bind(mod .. " + A",      hl.dsp.exec_cmd(browser))
hl.bind(mod .. " + C",      hl.dsp.window.close())
hl.bind(mod .. " + M",      hl.dsp.exec_cmd("uwsm stop"))

hl.bind(mod .. " + Z",      hl.dsp.window.float({ action = "toggle" }))  -- floating on/off
hl.bind(mod .. " + X",      hl.dsp.layout("togglesplit"))               -- split orientation
hl.bind(mod .. " + F",      hl.dsp.window.fullscreen(0))                -- fullscreen toggle
hl.bind(mod .. " + Space",  hl.dsp.exec_cmd("hyprctl switchxkblayout current next"))

-- Screenshots / recording
hl.bind("Print",        hl.dsp.exec_cmd("mkdir -p $HOME/Pictures/Screenshots && grimblast --freeze --notify copysave area"))  -- freeze, region -> clipboard + Pictures/Screenshots
hl.bind("CTRL + Print", hl.dsp.exec_cmd("screenrecord-toggle"))               -- start/stop region recording

-- Noctalia panels
hl.bind(mod .. " + S",      hl.dsp.exec_cmd(ipc .. "panel-toggle control-center"))
hl.bind(mod .. " + Escape", hl.dsp.exec_cmd(ipc .. "panel-toggle session"))
hl.bind(mod .. " + comma",  hl.dsp.exec_cmd(ipc .. "settings-toggle"))
hl.bind("ALT + Tab",        hl.dsp.exec_cmd(ipc .. "window-switcher"))

-- Focus
hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- Workspaces: SUPER + [0-9] to switch, + SHIFT to move the window
for i = 1, 10 do
    local key = i % 10
    hl.bind(mod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Move / resize with the mouse
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Media keys -> Noctalia
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd(ipc .. "volume-up"),       { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd(ipc .. "volume-down"),     { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd(ipc .. "volume-mute"),     { locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(ipc .. "brightness-up"),   { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(ipc .. "brightness-down"), { locked = true, repeating = true })

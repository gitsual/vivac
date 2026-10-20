-- Portable baseline distilled from the live workstation, as Lua. Anything that
-- depends on the machine (monitors, input devices, GPU) lives in the generated
-- fragments loaded below, rendered by scripts/render-config.sh from hardware
-- facts. The owner's local.lua is loaded last, guarded, and wins.
--
-- Binds are literal one-line hl.bind("MODS + KEY", ...) calls with a
-- "-- @help: <pane> <label_key>" line right above: scripts/check-help-registry.sh
-- reads them without running Lua, so a loop or a built key is refused there.

-- The config directory follows XDG_CONFIG_HOME, as Hyprland itself does.
local config_home = os.getenv("XDG_CONFIG_HOME")
if not config_home or config_home == "" then
	config_home = os.getenv("HOME") .. "/.config"
end
package.path = config_home .. "/hypr/?.lua;" .. package.path

-- Loads generated/<name>.lua afresh on every (re)load: require alone would
-- hand back the cached module if the Lua state outlives a reload.
local function fragment(name)
	local module = "generated." .. name
	package.loaded[module] = nil
	require(module)
end

-- What local.lua can rely on: the terminal, the scripts directory, and the
-- ordered list of programs started with the session. To take a vivac key,
-- call hl.unbind("MODS + KEY") first and bind it again.
vivac = { autostart = {} }
vivac.terminal = "kitty"
vivac.scripts = "$HOME/.config/hypr/scripts"

-- autostart_set(id, cmd) replaces the command of entry id, or appends it when
-- there is none; autostart_set(id, false) removes the entry.
function vivac.autostart_set(id, cmd)
	for index, entry in ipairs(vivac.autostart) do
		if entry.id == id then
			if cmd then
				entry.cmd = cmd
			else
				table.remove(vivac.autostart, index)
			end
			return
		end
	end
	if cmd then
		table.insert(vivac.autostart, { id = id, cmd = cmd })
	end
end

hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("GDK_BACKEND", "wayland")
hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "24")

fragment("hardware")
fragment("monitors")
fragment("input")

-- Where the checkout lives, for the programs started below. A checkout that is
-- not at ~/vivac names itself in <config>/vivac/repo (scripts/deploy-host.sh).
local repo_file = io.open(config_home .. "/vivac/repo")
if repo_file then
	local repo = repo_file:read("l")
	repo_file:close()
	if repo and repo ~= "" then
		hl.env("VIVAC_REPO", repo)
	end
end

hl.config({
	general = {
		gaps_in = 8,
		gaps_out = 15,
		border_size = 3,
		col = {
			active_border = { colors = { "rgb(E1777D)", "rgb(979367)" }, angle = 45 },
			inactive_border = "rgb(7C606E)",
		},
		layout = "dwindle",
	},
	decoration = {
		rounding = 10,
		active_opacity = 1.0,
		inactive_opacity = 0.95,
		dim_inactive = true,
		dim_strength = 0.2,
	},
	animations = { enabled = true },
	dwindle = { preserve_split = true },
	master = { new_on_top = true },
})

hl.curve("warmEase", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
hl.curve("overshot", { type = "bezier", points = { { 0.13, 0.99 }, { 0.29, 1.1 } } })
hl.animation({ leaf = "windows", enabled = true, speed = 4, bezier = "overshot", style = "slide" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 7, bezier = "warmEase" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 7, bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 7, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "fade", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "overshot", style = "slidevert" })

-- @help: hypr help.hypr.terminal
hl.bind("SUPER + Return", hl.dsp.exec_cmd(vivac.terminal))
-- @help: hypr help.hypr.launcher
hl.bind("SUPER + R", hl.dsp.exec_cmd("rofi -show drun"))
-- @help: hypr help.hypr.dmenu
hl.bind("SUPER + D", hl.dsp.exec_cmd([[dmenu_run -fn 'JetBrains Mono Nerd Font-12' -nb '#2D1F2D' -nf '#E8D5AB' -sb '#E1777D' -sf '#2D1F2D']]))
-- @help: hypr help.hypr.wofi
hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd("wofi --show drun"))
-- @help: hypr help.hypr.editor
hl.bind("SUPER + E", hl.dsp.exec_cmd(vivac.terminal .. " -e nvim"))
-- @help: hypr help.hypr.close
hl.bind("SUPER + Q", hl.dsp.window.close())
-- @help: hypr help.hypr.exit
hl.bind("SUPER + M", hl.dsp.exit())
-- @help: hypr help.hypr.floating
hl.bind("SUPER + Space", hl.dsp.window.float({ action = "toggle" }))
-- @help: hypr help.hypr.fullscreen
hl.bind("SUPER + F", hl.dsp.window.fullscreen())
-- @help: hypr help.hypr.split
hl.bind("SUPER + J", hl.dsp.layout("togglesplit"))
-- @help: hypr help.hypr.lock
hl.bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"))
-- @help: hypr help.hypr.screenshot
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(vivac.scripts .. "/screenshot.sh"))
-- @help: hypr help.hypr.help_hypr
hl.bind("F1", hl.dsp.exec_cmd(vivac.scripts .. "/help-pane.sh --pane hypr"))
-- @help: hypr help.hypr.help_browser
hl.bind("F2", hl.dsp.exec_cmd(vivac.scripts .. "/help-pane.sh --pane browser"))
-- @help: hypr help.hypr.help_shell
hl.bind("F3", hl.dsp.exec_cmd(vivac.scripts .. "/help-pane.sh --pane shell"))
-- @help: hypr help.hypr.help_editor
hl.bind("F4", hl.dsp.exec_cmd(vivac.scripts .. "/help-pane.sh --pane editor"))
-- @help: hypr help.hypr.help_system
hl.bind("F5", hl.dsp.exec_cmd(vivac.scripts .. "/help-pane.sh --pane system"))
-- @help: hypr help.hypr.power
hl.bind("SUPER + SHIFT + E", hl.dsp.exec_cmd("$HOME/.config/rofi/power/powermenu.sh"))
-- @help: hypr help.hypr.power_bar
hl.bind("SUPER + SHIFT + Q", hl.dsp.exec_cmd("$HOME/.local/bin/vivac-power"))
-- @help: hypr help.hypr.theme
hl.bind("SUPER + SHIFT + T", hl.dsp.exec_cmd("$HOME/.local/bin/vivac-theme"))
-- @help: hypr help.hypr.clipboard
hl.bind("SUPER + V", hl.dsp.exec_cmd("cliphist list | rofi -dmenu -i -p Clipboard | cliphist decode | wl-copy"))
-- @help: hypr help.hypr.reload
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))

-- @help: hypr help.hypr.focus_left
hl.bind("SUPER + left", hl.dsp.focus({ direction = "left" }))
-- @help: hypr help.hypr.focus_right
hl.bind("SUPER + right", hl.dsp.focus({ direction = "right" }))
-- @help: hypr help.hypr.focus_up
hl.bind("SUPER + up", hl.dsp.focus({ direction = "up" }))
-- @help: hypr help.hypr.focus_down
hl.bind("SUPER + down", hl.dsp.focus({ direction = "down" }))
-- @help: hypr help.hypr.move_left
hl.bind("SUPER + SHIFT + left", hl.dsp.window.move({ direction = "left" }))
-- @help: hypr help.hypr.move_right
hl.bind("SUPER + SHIFT + right", hl.dsp.window.move({ direction = "right" }))
-- @help: hypr help.hypr.move_up
hl.bind("SUPER + SHIFT + up", hl.dsp.window.move({ direction = "up" }))
-- @help: hypr help.hypr.move_down
hl.bind("SUPER + SHIFT + down", hl.dsp.window.move({ direction = "down" }))
-- @help: hypr help.hypr.shrink_w
hl.bind("SUPER + ALT + left", hl.dsp.window.resize({ x = -10, y = 0, relative = true }))
-- @help: hypr help.hypr.grow_w
hl.bind("SUPER + ALT + right", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
-- @help: hypr help.hypr.shrink_h
hl.bind("SUPER + ALT + up", hl.dsp.window.resize({ x = 0, y = -10, relative = true }))
-- @help: hypr help.hypr.grow_h
hl.bind("SUPER + ALT + down", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))

-- @help: hypr help.hypr.ws_1
hl.bind("SUPER + 1", hl.dsp.focus({ workspace = 1 }))
-- @help: hypr help.hypr.ws_2
hl.bind("SUPER + 2", hl.dsp.focus({ workspace = 2 }))
-- @help: hypr help.hypr.ws_3
hl.bind("SUPER + 3", hl.dsp.focus({ workspace = 3 }))
-- @help: hypr help.hypr.ws_4
hl.bind("SUPER + 4", hl.dsp.focus({ workspace = 4 }))
-- @help: hypr help.hypr.ws_5
hl.bind("SUPER + 5", hl.dsp.focus({ workspace = 5 }))
-- @help: hypr help.hypr.ws_6
hl.bind("SUPER + 6", hl.dsp.focus({ workspace = 6 }))
-- @help: hypr help.hypr.ws_7
hl.bind("SUPER + 7", hl.dsp.focus({ workspace = 7 }))
-- @help: hypr help.hypr.ws_8
hl.bind("SUPER + 8", hl.dsp.focus({ workspace = 8 }))
-- @help: hypr help.hypr.ws_9
hl.bind("SUPER + 9", hl.dsp.focus({ workspace = 9 }))
-- @help: hypr help.hypr.ws_10
hl.bind("SUPER + 0", hl.dsp.focus({ workspace = 10 }))
-- @help: hypr help.hypr.ws_move_1
hl.bind("SUPER + SHIFT + 1", hl.dsp.window.move({ workspace = 1 }))
-- @help: hypr help.hypr.ws_move_2
hl.bind("SUPER + SHIFT + 2", hl.dsp.window.move({ workspace = 2 }))
-- @help: hypr help.hypr.ws_move_3
hl.bind("SUPER + SHIFT + 3", hl.dsp.window.move({ workspace = 3 }))
-- @help: hypr help.hypr.ws_move_4
hl.bind("SUPER + SHIFT + 4", hl.dsp.window.move({ workspace = 4 }))
-- @help: hypr help.hypr.ws_move_5
hl.bind("SUPER + SHIFT + 5", hl.dsp.window.move({ workspace = 5 }))
-- @help: hypr help.hypr.ws_move_6
hl.bind("SUPER + SHIFT + 6", hl.dsp.window.move({ workspace = 6 }))
-- @help: hypr help.hypr.ws_move_7
hl.bind("SUPER + SHIFT + 7", hl.dsp.window.move({ workspace = 7 }))
-- @help: hypr help.hypr.ws_move_8
hl.bind("SUPER + SHIFT + 8", hl.dsp.window.move({ workspace = 8 }))
-- @help: hypr help.hypr.ws_move_9
hl.bind("SUPER + SHIFT + 9", hl.dsp.window.move({ workspace = 9 }))
-- @help: hypr help.hypr.ws_move_10
hl.bind("SUPER + SHIFT + 0", hl.dsp.window.move({ workspace = 10 }))
-- Walk the numbered workspaces in order and wrap at the ends (e = existing,
-- with wraparound). Special workspaces are never part of this sequence.
-- @help: hypr help.hypr.ws_next
hl.bind("SUPER + bracketright", hl.dsp.focus({ workspace = "e+1" }))
-- @help: hypr help.hypr.ws_prev
hl.bind("SUPER + bracketleft", hl.dsp.focus({ workspace = "e-1" }))

-- Apps that remember being maximized ask for it again on launch; honouring
-- that makes a new window cover the workspace instead of splitting it.
hl.window_rule({ name = "suppress-maximize", match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({ name = "pavucontrol", match = { class = "^(pavucontrol)$" }, float = true, center = true })
hl.window_rule({ name = "rofi-slide", match = { class = "^(rofi)$" }, animation = "slide" })
hl.window_rule({ name = "nm-connection-editor", match = { class = "^(nm-connection-editor)$" }, float = true })
-- The wizard is the only thing on screen while it runs: floating, centred and
-- large enough to read without leaning in.
hl.window_rule({ name = "vivac-welcome", match = { class = "^(vivac-welcome)$" }, float = true, center = true, size = "1100 700" })

-- Started with the session, in this order, once the compositor is up.
-- The pull of the optional shared settings (it does nothing when none are
-- configured) is listed first, but every entry here starts at once, so it does
-- not finish before the bar starts. That is fine: a theme it changes goes
-- through apply-theme, which reloads the bar and the notifications itself.
table.insert(vivac.autostart, { id = "sync-shared", cmd = "${VIVAC_REPO:-$HOME/vivac}/scripts/sync-shared-settings.sh --pull" })
table.insert(vivac.autostart, { id = "waybar", cmd = "waybar" })
table.insert(vivac.autostart, { id = "hypridle", cmd = "hypridle" })
-- Clipboard history for the picker above; harmless when cliphist is absent.
table.insert(vivac.autostart, { id = "cliphist", cmd = "wl-paste --watch cliphist store" })
table.insert(vivac.autostart, { id = "ws-refresh", cmd = "$HOME/.config/waybar/scripts/ws-refresh.sh" })
table.insert(vivac.autostart, { id = "dunst", cmd = "dunst" })
table.insert(vivac.autostart, { id = "wallpaper", cmd = "bash " .. vivac.scripts .. "/wallpaper.sh" })
table.insert(vivac.autostart, { id = "polkit", cmd = "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" })
table.insert(vivac.autostart, { id = "keyring", cmd = "/usr/bin/gnome-keyring-daemon --start --components=secrets,ssh,pkcs11" })
table.insert(vivac.autostart, { id = "dbus-env", cmd = "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP" })
-- The first session, and only the first: the wizard writes a marker and
-- --first-run is a no-op afterwards. It is started last so the bar, the
-- wallpaper and the notification daemon are already up to be previewed.
table.insert(vivac.autostart, { id = "welcome", cmd = vivac.terminal .. " --class vivac-welcome -e $HOME/.local/bin/vivac-welcome --first-run" })

hl.on("hyprland.start", function()
	for _, entry in ipairs(vivac.autostart) do
		hl.exec_cmd(entry.cmd)
	end
end)

-- The owner's file comes last and is the only thing here run under pcall: a
-- missing local.lua is the normal case, and a broken one is logged and
-- announced, never allowed to cost the session its keys, bar or wallpaper.
-- It is loaded with loadfile + pcall rather than require, because Hyprland
-- counts every error that passes through require as a config error, so
-- --verify-config would fail on the owner's typo even though nothing is lost.
-- Nothing may be added below this block.
local owner = package.searchpath("local", config_home .. "/hypr/?.lua")
if owner then
	local chunk, failure = loadfile(owner)
	if chunk then
		local ran, problem = pcall(chunk)
		if not ran then
			failure = problem
		end
	end
	if failure then
		print("vivac: local.lua failed: " .. tostring(failure))
		pcall(hl.notification.create, { text = "vivac: local.lua failed, see the Hyprland log", timeout = 10000 })
	end
end

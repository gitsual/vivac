-- The editor's palette, rendered like every other themed surface.
--
-- NvChad ships a catalogue of base46 themes and picking the nearest one to the
-- desktop would have been a mood, not a derivation: its hexes exist in no
-- corpus here, and it would drift the moment a palette changed. So the theme
-- is generated instead. base46 looks a custom theme up as `themes.<name>` in
-- the user's own config, which is exactly where Stow puts this file.
--
-- Two rules hold the mapping honest. Nothing invents a hue: every value below
-- is a palette token or one of the sanctioned derivations of one, so a colour
-- with no cause cannot reach the editor either. And the editor sits on
-- TERMINAL_BG rather than COLOR_BG, because it lives inside the terminal --
-- the warm chrome of the desktop is for borders and bars, not for text read
-- for hours.
--
-- Hex is written upper-case here, unfiltered: the derived shades come out of
-- render_scale_channels that way and a file that mixed the two notations for
-- the same kind of value would look like two authors.

local M = {}

M.base_30 = {
	white = "#E8D5AB",
	darker_black = "#100D12",
	black = "#18131B",
	black2 = "#342A31",
	one_bg = "#43363F",
	one_bg2 = "#5A4855",
	one_bg3 = "#604A55",
	grey = "#7C606E",
	grey_fg = "#958674",
	grey_fg2 = "#C0AD95",
	light_grey = "#C0AD95",
	line = "#5A4855",
	statusline_bg = "#342A31",
	lightbg = "#43363F",
	pmenu_bg = "#E1777D",
	folder_bg = "#6CA4B1",

	-- The semantic half. A palette carries one colour per meaning, not one per
	-- name base46 happens to use, so several of these names share a token on
	-- purpose: red is what the desktop calls urgent, green is what it calls ok.
	red = "#BD6161",
	green = "#55A185",
	vibrant_green = "#55A185",
	teal = "#427D67",
	blue = "#6CA4B1",
	nord_blue = "#547F8A",
	cyan = "#6CA4B1",
	yellow = "#979367",
	sun = "#979367",
	orange = "#E1777D",
	purple = "#E1777D",
	dark_purple = "#AF5C61",
	pink = "#E1777D",
	baby_pink = "#AF5C61",
}

M.base_16 = {
	base00 = "#18131B",
	base01 = "#342A31",
	base02 = "#43363F",
	base03 = "#7C606E",
	base04 = "#C0AD95",
	base05 = "#E8D5AB",
	base06 = "#E8D5AB",
	base07 = "#E8D5AB",
	base08 = "#BD6161",
	base09 = "#979367",
	base0A = "#979367",
	base0B = "#55A185",
	base0C = "#6CA4B1",
	base0D = "#6CA4B1",
	base0E = "#E1777D",
	base0F = "#AF5C61",
}

M.type = "dark"

return M

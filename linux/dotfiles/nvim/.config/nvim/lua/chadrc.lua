-- This file needs to have same structure as nvconfig.lua 
-- https://github.com/NvChad/ui/blob/v3.0/lua/nvconfig.lua
-- Please read that file to know all available options :( 

---@type ChadrcConfig
local M = {}

M.base46 = {
	-- Not one of the themes base46 ships: this one is rendered from the
	-- desktop palette into lua/themes/vivac.lua, so the editor changes
	-- colour with everything else instead of staying the one surface that
	-- ignored the theme.
	theme = "vivac",

	-- hl_override = {
	-- 	Comment = { italic = true },
	-- 	["@comment"] = { italic = true },
	-- },
}

return M

local M = {}

local function valid_win(winid)
  return type(winid) == "number" and vim.api.nvim_win_is_valid(winid)
end

local function notify_once(key, msg)
  local flag = "avante_compat_notified_" .. key
  if vim.g[flag] then return end
  vim.g[flag] = true
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.DEBUG, { title = "Avante compat" })
  end)
end

function M.patch_window_guards()
  local ok_utils, Utils = pcall(require, "avante.utils")
  if not ok_utils or rawget(Utils, "__portfolio_window_guard_patch") then return end
  rawset(Utils, "__portfolio_window_guard_patch", true)

  local original_is_top_adjacent = Utils.is_top_adjacent
  local original_should_hidden_border = Utils.should_hidden_border

  Utils.is_top_adjacent = function(win_a, win_b)
    if not valid_win(win_a) or not valid_win(win_b) then return false end
    local ok, result = pcall(original_is_top_adjacent, win_a, win_b)
    if ok then return result end
    notify_once("top_adjacent", "Ignorado winid inválido en Avante Utils.is_top_adjacent")
    return false
  end

  Utils.should_hidden_border = function(win_a, win_b)
    if not valid_win(win_a) or not valid_win(win_b) then return false end
    local ok, result = pcall(original_should_hidden_border, win_a, win_b)
    if ok then return result end
    notify_once("hidden_border", "Ignorado winid inválido en Avante Utils.should_hidden_border")
    return false
  end
end

function M.patch_sidebar_hints()
  local ok_sidebar, Sidebar = pcall(require, "avante.sidebar")
  if not ok_sidebar or rawget(Sidebar, "__portfolio_input_hint_patch") then return end
  rawset(Sidebar, "__portfolio_input_hint_patch", true)

  local original_show_input_hint = Sidebar.show_input_hint
  local original_get_input_float_window_row = Sidebar.get_input_float_window_row

  Sidebar.get_input_float_window_row = function(self, ...)
    if not self or not self.containers or not self.containers.input or not valid_win(self.containers.input.winid) then
      return 0
    end
    local ok, result = pcall(original_get_input_float_window_row, self, ...)
    return ok and result or 0
  end

  Sidebar.show_input_hint = function(self, ...)
    if not self or not self.containers or not self.containers.input or not valid_win(self.containers.input.winid) then
      return
    end
    local ok, err = pcall(original_show_input_hint, self, ...)
    if not ok then
      notify_once("show_input_hint", "Ignorado error no crítico en Avante show_input_hint: " .. tostring(err))
    end
  end
end

function M.setup()
  M.patch_window_guards()
  M.patch_sidebar_hints()
end

return M

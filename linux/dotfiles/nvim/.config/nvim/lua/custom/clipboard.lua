local M = {}

M.setup = function()
  -- Configurar Neovim para usar el portapapeles de Wayland correctamente
  vim.g.clipboard = {
    name = 'WL-Clipboard',
    copy = {
      ['+'] = {'wl-copy', '--type', 'text/plain'},
      ['*'] = {'wl-copy', '--primary', '--type', 'text/plain'},
    },
    paste = {
      ['+'] = {'wl-paste', '--no-newline'},
      ['*'] = {'wl-paste', '--primary', '--no-newline'},
    },
    cache_enabled = true,
  }
end

return M


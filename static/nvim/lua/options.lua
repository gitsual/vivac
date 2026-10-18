require "nvchad.options"

-- Neovim on Windows has no clipboard provider of its own unless win32yank is
-- on the PATH; this one uses the PowerShell that ships with Windows.
require("custom.clipboard").setup()

-- add yours here!

-- local o = vim.o
-- o.cursorlineopt ='both' -- to enable cursorline!

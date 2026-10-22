local M = {}

-- The Windows clipboard, through the PowerShell that ships with Windows.
-- clip.exe is not used for copying: it writes in the console code page and
-- mangles anything outside ASCII, where Set-Clipboard keeps UTF-8 intact.
M.setup = function()
  local ps = { 'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command' }
  local copy = vim.list_extend(vim.deepcopy(ps), {
    '[Console]::InputEncoding = [Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())',
  })
  local paste = vim.list_extend(vim.deepcopy(ps), {
    '[Console]::OutputEncoding = [Text.Encoding]::UTF8; $c = Get-Clipboard -Raw; if ($c) { [Console]::Out.Write($c -replace "`r", "") }',
  })
  vim.g.clipboard = {
    name = 'WindowsClipboard',
    copy = { ['+'] = copy, ['*'] = copy },
    paste = { ['+'] = paste, ['*'] = paste },
    cache_enabled = 0,
  }
end

return M

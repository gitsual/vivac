-- load defaults i.e lua_lsp
local nvlsp = require "nvchad.configs.lspconfig"
nvlsp.defaults()

-- Servers are declared through vim.lsp, not through the lspconfig module:
-- requiring "lspconfig" is deprecated since nvim-lspconfig v3 and greets every
-- launch with a warning the user has to dismiss before the file appears.
local servers = { "html", "cssls" }

for _, lsp in ipairs(servers) do
  vim.lsp.config(lsp, {
    on_attach = nvlsp.on_attach,
    on_init = nvlsp.on_init,
    capabilities = nvlsp.capabilities,
  })
  vim.lsp.enable(lsp)
end

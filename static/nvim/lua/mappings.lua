require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")
map("n", "<leader>aa", "<cmd>AvanteToggle<CR>", { desc = "Avante: panel" })
map("n", "<leader>ac", "<cmd>AvanteChat<CR>", { desc = "Avante: chat" })
map("n", "<leader>an", ":AvanteAsk ", { desc = "Avante: preguntar" })
map("v", "<leader>ae", ":AvanteEdit ", { desc = "Avante: editar selección" })
map("n", "<leader>af", "<cmd>AIFilePicker<CR>", { desc = "AI: seleccionar ficheros" })
map("n", "<leader>ad", "<cmd>AIAddBuffer<CR>", { desc = "AI: añadir buffer actual" })
map("n", "<leader>aB", "<cmd>AIAddBuffers<CR>", { desc = "AI: añadir todos los buffers" })
map("n", "<leader>aq", "<cmd>AIAddQuickfix<CR>", { desc = "AI: añadir quickfix" })
map("n", "<leader>ah", "<cmd>AIDropHelp<CR>", { desc = "AI: ayuda drag&drop" })
map("n", "<leader>ap", "<cmd>AISelect<CR>", { desc = "Avante: selector modelo/provider" })
map("n", "<leader>aP", "<cmd>AIProvider<CR>", { desc = "Avante: elegir proveedor" })
map("n", "<leader>a1", "<cmd>AIProviderOpenAI<CR>", { desc = "AI: Avante ChatGPT/OpenAI" })
map("n", "<leader>a2", "<cmd>AIProviderGemini<CR>", { desc = "AI: Avante Gemini" })
map("n", "<leader>a3", "<cmd>AIProviderClaude<CR>", { desc = "AI: Avante Claude" })
map("n", "<leader>am", ":AIModel ", { desc = "AI: cambiar modelo Avante" })
map("n", "<leader>aM1", ":AIModelOpenAI ", { desc = "AI: modelo ChatGPT/OpenAI" })
map("n", "<leader>aM2", ":AIModelGemini ", { desc = "AI: modelo Gemini" })
map("n", "<leader>aM3", ":AIModelClaude ", { desc = "AI: modelo Claude" })
map("n", "<leader>aO", "<cmd>AvanteModels<CR>", { desc = "Avante: selector oficial de modelos" })
map("n", "<leader>ag", "<cmd>AIAgentSelect<CR>", { desc = "Avante: nuevo agente en pestaña" })
map("n", "<leader>aG", ":AIAgent ", { desc = "Avante: nuevo agente" })
-- Todo el flujo IA de Neovim pasa por Avante. Los comandos de compatibilidad
-- :AICodex, :AIClaude y :AIGemini ahora seleccionan provider/modelo en Avante
-- y abren/preguntan desde Avante; ya no lanzan terminales con CLIs.
-- En el input de Avante también funcionan: @file, @buffers, @quickfix, /help, #refactor, #tests, #review, #explain
-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")

local M = {}

-- Configuración de Refact
--M.refact = {
--  n = {
    -- Comando para completar código
--    ["<leader>rc"] = { 
--      "<cmd>RefactComplete<CR>", 
--      "Refact Complete" 
--    },
    
    -- Comando para explicar código
--    ["<leader>re"] = { 
--      "<cmd>RefactExplain<CR>", 
--      "Refact Explain" 
--    },
    
    -- Comando para reescribir código
--    ["<leader>rr"] = { 
--      "<cmd>RefactRewrite<CR>", 
--      "Refact Rewrite" 
--    },
--  }
--}

return M

local M = {}

-- Avante-only AI workflow.
-- Importante: Avante.nvim habla con providers HTTP/API. Aquí eliminamos la
-- ruta de terminal/CLI para que todos los selectores, agentes y alias usen la
-- UI de Avante. Los CLIs siguen instalados en el sistema, pero Neovim ya no los
-- abre desde los comandos <leader>a* ni :AI*.

local providers = {
  -- *cli usa proxies locales Avante -> CLI, por tanto aprovecha la
  -- suscripción/login de cada CLI y no requiere API keys.
  codexcli = { label = "Codex CLI / suscripción", avante = "codexcli" },
  openai = { label = "ChatGPT / Codex CLI", avante = "codexcli" },
  chatgpt = { label = "ChatGPT / Codex CLI", avante = "codexcli" },
  codex = { label = "Codex CLI / suscripción", avante = "codexcli" },
  claudecli = { label = "Claude CLI / suscripción", avante = "claudecli" },
  claude = { label = "Claude CLI / suscripción", avante = "claudecli" },
  geminicli = { label = "Gemini CLI / suscripción", avante = "geminicli" },
  gemini = { label = "Gemini CLI / suscripción", avante = "geminicli" },
  ollama = { label = "Ollama local", avante = "ollama" },
}

local model_presets = {
  { provider = "codexcli", model = vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5", label = "Avante · Codex CLI / suscripción sin API key" },
  { provider = "claudecli", model = vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet", label = "Avante · Claude CLI / suscripción sin API key" },
  { provider = "geminicli", model = vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash", label = "Avante · Gemini CLI / suscripción sin API key" },
  { provider = "ollama", model = vim.env.AVANTE_OLLAMA_MODEL or "qwen2.5-coder:7b", label = "Avante · Ollama local sin API key" },
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Avante" })
end

local function resolve_provider(name)
  name = (name or ""):lower()
  local spec = providers[name]
  return spec and spec.avante or nil
end

local function provider_label(provider)
  for _, spec in pairs(providers) do
    if spec.avante == provider then return spec.label end
  end
  return provider
end

local function provider_has_auth(provider)
  if provider == "codexcli" then return vim.fn.executable("codex") == 1 end
  if provider == "claudecli" then return vim.fn.executable("claude") == 1 end
  if provider == "geminicli" then return vim.fn.executable("gemini") == 1 end
  if provider == "ollama" then return true end
  if provider == "gemini" then return vim.env.GEMINI_API_KEY ~= nil or vim.env.AVANTE_GEMINI_API_KEY ~= nil end
  if provider == "openai" then return vim.env.OPENAI_API_KEY ~= nil or vim.env.AVANTE_OPENAI_API_KEY ~= nil end
  if provider == "claude" then return vim.env.ANTHROPIC_API_KEY ~= nil or vim.env.AVANTE_ANTHROPIC_API_KEY ~= nil end
  return true
end

local function warn_auth_if_needed(provider)
  if provider_has_auth(provider) then return end
  if provider == "codexcli" then
    notify("Avante está en Codex CLI, pero no encuentro el comando codex. Revisa PATH y el servicio avante-codex-proxy.", vim.log.levels.WARN)
    return
  end
  if provider == "claudecli" then
    notify("Avante está en Claude CLI, pero no encuentro el comando claude. Revisa PATH y el servicio avante-claude-proxy.", vim.log.levels.WARN)
    return
  end
  if provider == "geminicli" then
    notify("Avante está en Gemini CLI, pero no encuentro el comando gemini. Revisa PATH y el servicio avante-gemini-proxy.", vim.log.levels.WARN)
    return
  end
  local key = ({ openai = "OPENAI_API_KEY", claude = "ANTHROPIC_API_KEY", gemini = "GEMINI_API_KEY" })[provider]
  if key then
    notify("Avante está en " .. provider .. ", pero no veo " .. key .. " en el entorno de Neovim. Si Avante la pide, exporta esa variable o usa :AIModel codexcli gpt-5.5 o :AIModel ollama qwen2.5-coder:7b.", vim.log.levels.WARN)
  end
end

function M.switch_avante_provider(name)
  local provider = resolve_provider(name)
  if not provider then
    notify("Proveedor desconocido: " .. ((name or "") == "" and "<vacío>" or name) .. ". Usa: codex/codexcli, claude/claudecli, gemini/geminicli, ollama u openai/chatgpt.", vim.log.levels.ERROR)
    return
  end

  local ok, Config = pcall(require, "avante.config")
  if not ok then
    notify("No he podido cargar avante.config", vim.log.levels.ERROR)
    return
  end

  Config.override({ provider = provider })
  warn_auth_if_needed(provider)
  notify("Avante ahora usará " .. provider_label(provider) .. " (provider: " .. provider .. ")")
end

function M.set_avante_model(provider_name, model)
  model = vim.trim(model or "")
  if model == "" then
    notify("Falta el modelo. Ejemplo: :AIModel gemini gemini-2.5-flash", vim.log.levels.ERROR)
    return
  end

  local provider = resolve_provider(provider_name)
  if not provider then
    notify("Proveedor desconocido: " .. ((provider_name or "") == "" and "<vacío>" or provider_name), vim.log.levels.ERROR)
    return
  end

  local ok, Config = pcall(require, "avante.config")
  if not ok or not Config.providers or not Config.providers[provider] then
    notify("No he podido acceder a la configuración de Avante para " .. provider, vim.log.levels.ERROR)
    return
  end

  Config.providers[provider].model = model
  Config.override({ provider = provider })
  vim.t.ai_provider = provider
  vim.t.ai_model = model
  warn_auth_if_needed(provider)
  notify(("Avante usará %s con modelo: %s"):format(provider, model))
end

function M.prompt_avante_model(provider_name)
  local provider = resolve_provider(provider_name)
  if not provider then return notify("Proveedor desconocido: " .. tostring(provider_name), vim.log.levels.ERROR) end
  local ok, Config = pcall(require, "avante.config")
  local current = ok and Config.providers and Config.providers[provider] and Config.providers[provider].model or ""
  vim.ui.input({ prompt = "Modelo Avante para " .. provider .. ": ", default = current }, function(model)
    if model then M.set_avante_model(provider, model) end
  end)
end

function M.apply_tab_ai_config()
  local provider = vim.t.ai_provider
  local model = vim.t.ai_model
  if not provider or not model then return end
  local ok, Config = pcall(require, "avante.config")
  if not ok or not Config.providers or not Config.providers[provider] then return end
  Config.providers[provider].model = model
  Config.override({ provider = provider })
end

local function open_avante_sidebar()
  local ok, avante = pcall(require, "avante")
  if ok and avante.open_sidebar then
    avante.open_sidebar({ ask = false })
    local sidebar = avante.get and avante.get() or nil
    if sidebar and sidebar.focus_input then vim.schedule(function() pcall(function() sidebar:focus_input() end) end) end
    return
  end
  pcall(vim.cmd, "AvanteChat")
end

local function ask_avante(prompt)
  prompt = vim.trim(prompt or "")
  if prompt == "" then return open_avante_sidebar() end
  -- AvanteAsk recibe el resto de la línea como pregunta. Escapamos barras y pipes
  -- para que no rompa el command-line, pero mantenemos el texto legible.
  local safe = vim.fn.escape(prompt, "\\|")
  vim.cmd("AvanteAsk " .. safe)
end

function M.open_agent_tab(provider_name, model, title, prompt)
  local provider = resolve_provider(provider_name)
  if not provider then
    notify("Proveedor desconocido: " .. tostring(provider_name), vim.log.levels.ERROR)
    return
  end
  model = vim.trim(model or "")
  if model == "" then return M.prompt_avante_model(provider) end

  vim.cmd("tabnew")
  vim.t.ai_provider = provider
  vim.t.ai_model = model
  vim.t.ai_agent_name = title or (provider_label(provider) .. " · " .. model)
  M.apply_tab_ai_config()
  open_avante_sidebar()

  local sidebar_ok, avante = pcall(require, "avante")
  if sidebar_ok and avante.get then
    local sidebar = avante.get()
    if sidebar then
      if sidebar.new_chat then pcall(function() sidebar:new_chat() end) end
      if sidebar.clear_history then pcall(function() sidebar:clear_history() end) end
      if sidebar.focus_input then vim.schedule(function() pcall(function() sidebar:focus_input() end) end) end
    end
  end

  if prompt and vim.trim(prompt) ~= "" then vim.schedule(function() ask_avante(prompt) end) end
  warn_auth_if_needed(provider)
  notify("Agente Avante creado en esta pestaña: " .. vim.t.ai_agent_name)
end

local function default_model_for(provider)
  provider = (provider or ""):lower()
  if provider == "codex" or provider == "codexcli" then return vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5" end
  if provider == "chatgpt" or provider == "openai" then return vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5" end
  if provider == "gemini" or provider == "geminicli" then return vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash" end
  if provider == "claude" or provider == "claudecli" then return vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet" end
  if provider == "ollama" then return vim.env.AVANTE_OLLAMA_MODEL or "qwen2.5-coder:7b" end
  return nil
end

local function looks_like_model(value)
  value = vim.trim(value or "")
  if value == "" then return false end
  return value:find(":", 1, true)
    or value:match("^gpt[%w%.-]*")
    or value:match("^o%d")
    or value:match("^gemini[%w%.-]*")
    or value:match("^claude[%w%.-]*")
    or value:match("^qwen[%w%.-]*")
    or value:match("^llama[%w%.-]*")
    or value:match("^mistral[%w%.-]*")
end

function M.open_agent_from_args(args)
  args = vim.trim(args or "")
  if args == "" then return M.select_ai({ agent = true }) end

  local provider, tail = args:match("^(%S+)%s*(.*)$")
  if not provider or provider == "" then return M.select_ai({ agent = true }) end
  provider = provider:lower()

  local first, rest = (tail or ""):match("^(%S*)%s*(.*)$")
  local model = default_model_for(provider)
  local prompt_or_title = tail

  -- Soporta ambas formas:
  --   :AIAgent gemini arregla esto          -> modelo Gemini por defecto + prompt
  --   :AIAgent gemini gemini-2.5-flash bug -> modelo explícito + título/prompt
  if looks_like_model(first) then
    model = first
    prompt_or_title = rest
  end

  if not model then
    notify("Uso: :AIAgent <codex|claude|gemini|ollama> [modelo] [prompt/título]", vim.log.levels.ERROR)
    return
  end

  M.open_agent_tab(provider, model, nil, prompt_or_title ~= "" and prompt_or_title or nil)
end

function M.apply_preset(preset, opts)
  opts = opts or {}
  if not preset then return end
  if opts.agent then return M.open_agent_tab(preset.provider, preset.model, preset.label) end
  M.set_avante_model(preset.provider, preset.model)
  if opts.open then ask_avante("") end
end

function M.select_ai(opts)
  opts = opts or {}
  local items = vim.deepcopy(model_presets)
  table.insert(items, { kind = "custom", label = "Avante · provider + modelo personalizado" })

  vim.ui.select(items, {
    prompt = opts.agent and "Nuevo agente Avante" or "Modelo Avante",
    format_item = function(item) return item.label end,
  }, function(item)
    if not item then return end
    if item.kind == "custom" then
      vim.ui.input({ prompt = "Avante provider modelo (ej: gemini gemini-2.5-flash): " }, function(value)
        if not value or value == "" then return end
        local provider, model = value:match("^(%S+)%s+(.+)$")
        if not provider or not model then return notify("Uso: provider modelo", vim.log.levels.ERROR) end
        if opts.agent then M.open_agent_tab(provider, model) else M.set_avante_model(provider, model) end
      end)
      return
    end
    M.apply_preset(item, opts)
  end)
end

function M.show_status()
  local lines = {
    "Avante configurado como única interfaz IA en Neovim.",
    "",
    "Comandos principales:",
    "  :AISelect[!]              -> elegir modelo Avante; ! abre el panel",
    "  :AIAgent [provider model] -> nueva pestaña/agente Avante",
    "  :AIModel provider model   -> cambiar provider/modelo de Avante",
    "  :AICodex [prompt]         -> Avante usando Codex CLI/suscripción local",
    "  :AIClaude [prompt]        -> Avante usando Claude CLI/suscripción local",
    "  :AIGemini [prompt]        -> Avante usando Gemini CLI/suscripción local",
    "",
    "Estado de autenticación visible para Neovim:",
    "  Codex CLI/proxy local: " .. (provider_has_auth("codexcli") and "OK" or "NO"),
    "  Claude CLI/proxy local: " .. (provider_has_auth("claudecli") and "OK" or "NO"),
    "  Gemini CLI/proxy local: " .. (provider_has_auth("geminicli") and "OK" or "NO"),
    "  OPENAI_API_KEY/AVANTE_OPENAI_API_KEY: " .. (provider_has_auth("openai") and "OK" or "NO"),
    "  ANTHROPIC_API_KEY/AVANTE_ANTHROPIC_API_KEY: " .. (provider_has_auth("claude") and "OK" or "NO"),
    "  GEMINI_API_KEY/AVANTE_GEMINI_API_KEY: " .. (provider_has_auth("gemini") and "OK" or "NO"),
    "  Ollama local: OK sin API key",
    "",
    "Modelos Avante actuales:",
  }

  local ok, Config = pcall(require, "avante.config")
  if ok and Config.providers then
    for _, provider in ipairs({ "codexcli", "claudecli", "geminicli", "ollama", "openai", "gemini", "claude" }) do
      local model = Config.providers[provider] and Config.providers[provider].model or "<sin configurar>"
      table.insert(lines, ("  %-6s %s"):format(provider, model))
    end
    table.insert(lines, "")
    table.insert(lines, "Provider activo: " .. tostring(Config.provider))
  else
    table.insert(lines, "  No he podido leer avante.config")
  end

  notify(table.concat(lines, "\n"))
end

function M.setup_commands()
  vim.api.nvim_create_user_command("AIProvider", function(opts)
    if opts.args == "" then M.select_ai({ open = false }) else M.switch_avante_provider(opts.args) end
  end, {
    nargs = "?",
    complete = function() return { "codexcli", "codex", "claudecli", "claude", "geminicli", "gemini", "ollama", "openai", "chatgpt" } end,
    desc = "Cambia el proveedor Avante",
  })

  vim.api.nvim_create_user_command("AIProviderOpenAI", function() M.switch_avante_provider("codexcli") end, { desc = "Avante -> Codex CLI/ChatGPT sin API key" })
  vim.api.nvim_create_user_command("AIProviderChatGPT", function() M.switch_avante_provider("codexcli") end, { desc = "Avante -> Codex CLI/ChatGPT sin API key" })
  vim.api.nvim_create_user_command("AIProviderCodex", function() M.set_avante_model("codexcli", vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5") end, { desc = "Avante -> Codex CLI/suscripción" })
  vim.api.nvim_create_user_command("AIProviderGemini", function() M.set_avante_model("geminicli", vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash") end, { desc = "Avante -> Gemini CLI/suscripción" })
  vim.api.nvim_create_user_command("AIProviderClaude", function() M.set_avante_model("claudecli", vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet") end, { desc = "Avante -> Claude CLI/suscripción" })
  vim.api.nvim_create_user_command("AIProviderStatus", M.show_status, { desc = "Estado Avante" })

  vim.api.nvim_create_user_command("AISelect", function(opts) M.select_ai({ open = opts.bang }) end, { bang = true, desc = "Selector de modelos Avante" })
  vim.api.nvim_create_user_command("AIAgentSelect", function() M.select_ai({ agent = true }) end, { desc = "Nueva pestaña/agente Avante" })
  vim.api.nvim_create_user_command("AIAgent", function(opts) M.open_agent_from_args(opts.args) end, {
    nargs = "*",
    complete = function(arglead, cmdline)
      if cmdline:match("^%s*AIAgent%s+%S+%s+") then return {} end
      return vim.tbl_filter(function(item) return item:find(arglead, 1, true) == 1 end, { "codexcli", "codex", "claudecli", "claude", "geminicli", "gemini", "ollama", "openai", "chatgpt" })
    end,
    desc = "Crea una pestaña/agente Avante: :AIAgent provider [modelo]",
  })
  vim.api.nvim_create_user_command("AIAgentHere", function(opts)
    local provider, model = opts.args:match("^(%S+)%s+(.+)$")
    if not provider or not model then return notify("Uso: :AIAgentHere <provider> <modelo>", vim.log.levels.ERROR) end
    M.set_avante_model(provider, model)
    open_avante_sidebar()
  end, { nargs = "+", desc = "Convierte la pestaña actual en agente Avante con provider/modelo" })

  vim.api.nvim_create_user_command("AIModel", function(opts)
    local provider, model = opts.args:match("^(%S+)%s+(.+)$")
    if not provider or not model then return notify("Uso: :AIModel <codexcli|claudecli|geminicli|ollama> <modelo>", vim.log.levels.ERROR) end
    M.set_avante_model(provider, model)
  end, {
    nargs = "+",
    complete = function(arglead, cmdline)
      if cmdline:match("^%s*AIModel%s+%S+%s+") then return {} end
      return vim.tbl_filter(function(item) return item:find(arglead, 1, true) == 1 end, { "codexcli", "codex", "claudecli", "claude", "geminicli", "gemini", "ollama", "openai", "chatgpt" })
    end,
    desc = "Cambia provider/modelo de Avante",
  })
  vim.api.nvim_create_user_command("AIModelOpenAI", function(opts) if opts.args == "" then M.set_avante_model("codexcli", vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5") else M.set_avante_model("codexcli", opts.args) end end, { nargs = "*", desc = "Modelo Codex CLI/ChatGPT para Avante" })
  vim.api.nvim_create_user_command("AIModelChatGPT", function(opts) if opts.args == "" then M.set_avante_model("codexcli", vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5") else M.set_avante_model("codexcli", opts.args) end end, { nargs = "*", desc = "Modelo Codex CLI/ChatGPT para Avante" })
  vim.api.nvim_create_user_command("AIModelCodex", function(opts) if opts.args == "" then M.set_avante_model("codexcli", vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5") else M.set_avante_model("codexcli", opts.args) end end, { nargs = "*", desc = "Modelo Codex CLI para Avante" })
  vim.api.nvim_create_user_command("AIModelGemini", function(opts) if opts.args == "" then M.set_avante_model("geminicli", vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash") else M.set_avante_model("geminicli", opts.args) end end, { nargs = "*", desc = "Modelo Gemini CLI para Avante" })
  vim.api.nvim_create_user_command("AIModelClaude", function(opts) if opts.args == "" then M.set_avante_model("claudecli", vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet") else M.set_avante_model("claudecli", opts.args) end end, { nargs = "*", desc = "Modelo Claude CLI para Avante" })

  -- Compatibilidad con los comandos antiguos: ahora NO abren terminales/CLIs;
  -- seleccionan el provider en Avante y abren/preguntan desde Avante.
  vim.api.nvim_create_user_command("AICodex", function(opts) M.set_avante_model("codexcli", vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5"); ask_avante(opts.args) end, { nargs = "*", desc = "Avante Codex CLI/suscripción" })
  vim.api.nvim_create_user_command("AIGemini", function(opts) M.set_avante_model("geminicli", vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash"); ask_avante(opts.args) end, { nargs = "*", desc = "Avante Gemini CLI/suscripción" })
  vim.api.nvim_create_user_command("AIClaude", function(opts) M.set_avante_model("claudecli", vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet"); ask_avante(opts.args) end, { nargs = "*", desc = "Avante Claude CLI/suscripción" })
  vim.api.nvim_create_user_command("AICodexFile", function(opts) M.set_avante_model("codexcli", vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5"); ask_avante("Contexto: " .. vim.api.nvim_buf_get_name(0) .. "\n\n" .. opts.args) end, { nargs = "*", desc = "Avante Codex CLI/suscripción con fichero actual" })
  vim.api.nvim_create_user_command("AIGeminiFile", function(opts) M.set_avante_model("geminicli", vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash"); ask_avante("Contexto: " .. vim.api.nvim_buf_get_name(0) .. "\n\n" .. opts.args) end, { nargs = "*", desc = "Avante Gemini CLI/suscripción con fichero actual" })
  vim.api.nvim_create_user_command("AIClaudeFile", function(opts) M.set_avante_model("claudecli", vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet"); ask_avante("Contexto: " .. vim.api.nvim_buf_get_name(0) .. "\n\n" .. opts.args) end, { nargs = "*", desc = "Avante Claude CLI/suscripción con fichero actual" })
end

function M.setup()
  if vim.g.ai_agents_setup then return end
  vim.g.ai_agents_setup = true
  M.setup_commands()
  vim.api.nvim_create_autocmd("TabEnter", {
    group = vim.api.nvim_create_augroup("AIAvanteTabAgents", { clear = true }),
    callback = function() M.apply_tab_ai_config() end,
    desc = "Aplica provider/modelo Avante específico de cada pestaña/agente",
  })
end

return M

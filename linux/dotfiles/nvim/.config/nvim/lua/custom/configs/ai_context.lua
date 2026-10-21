local M = {}

local image_exts = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  bmp = true,
  tiff = true,
  tif = true,
  avif = true,
}

local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "AI context" })
  end)
end

local function shell_unescape(path)
  path = vim.trim(path or "")
  path = path:gsub("^%s*file://", "")
  path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  path = path:gsub("^['\"]", ""):gsub("['\"]$", "")
  path = path:gsub("\\ ", " ")
  return path
end

local function existing_path(path)
  path = shell_unescape(path)
  if path == "" then return nil end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.uv.fs_stat(path) then return path end
  return nil
end

function M.paths_from_text(text)
  local paths = {}
  local seen = {}

  local function add(candidate)
    local path = existing_path(candidate)
    if path and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end

  text = text or ""

  -- Newline-separated drops are common with terminals / file managers.
  for line in text:gmatch("[^\r\n]+") do
    add(line)
  end

  -- Some terminals paste multiple paths separated by spaces, with spaces inside
  -- filenames escaped as \ . This parser keeps escaped spaces intact.
  local current = {}
  local escaped = false
  for i = 1, #text do
    local ch = text:sub(i, i)
    if escaped then
      table.insert(current, ch)
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch:match("%s") then
      if #current > 0 then
        add(table.concat(current))
        current = {}
      end
    else
      table.insert(current, ch)
    end
  end
  if #current > 0 then add(table.concat(current)) end

  return paths
end

local function is_image(path)
  local ext = path:match("%.([^%.]+)$")
  return ext and image_exts[ext:lower()] or false
end

local function ensure_avante_sidebar()
  local api = require("avante.api")
  local sidebar = require("avante").get()
  if not sidebar then
    api.ask({ ask = false })
    sidebar = require("avante").get()
  end
  if sidebar and not sidebar:is_open() then sidebar:open({}) end
  return sidebar
end

function M.add_paths_to_avante(paths)
  if not paths or vim.tbl_isempty(paths) then
    notify("No he encontrado rutas válidas que añadir.", vim.log.levels.WARN)
    return
  end

  ensure_avante_sidebar()
  local api = require("avante.api")
  local added = 0
  for _, path in ipairs(paths) do
    api.add_selected_file(path)
    added = added + 1
  end
  notify(("Añadido(s) %d fichero(s)/directorio(s) al contexto de Avante."):format(added))
end

function M.add_current_buffer()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    notify("El buffer actual no tiene fichero asociado.", vim.log.levels.WARN)
    return
  end
  M.add_paths_to_avante({ path })
end

function M.add_all_buffers()
  local paths = {}
  local seen = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" and vim.uv.fs_stat(path) and not seen[path] then
        seen[path] = true
        table.insert(paths, path)
      end
    end
  end
  M.add_paths_to_avante(paths)
end

function M.add_quickfix()
  local paths = {}
  local seen = {}
  for _, item in ipairs(vim.fn.getqflist({ items = 0 }).items) do
    if item.bufnr and item.bufnr ~= 0 then
      local path = vim.api.nvim_buf_get_name(item.bufnr)
      if path ~= "" and vim.uv.fs_stat(path) and not seen[path] then
        seen[path] = true
        table.insert(paths, path)
      end
    end
  end
  M.add_paths_to_avante(paths)
end

function M.open_file_picker()
  local sidebar = ensure_avante_sidebar()
  if sidebar and sidebar.file_selector then
    sidebar.file_selector:open()
  else
    notify("No he podido abrir el selector de ficheros de Avante.", vim.log.levels.ERROR)
  end
end

function M.open_paths_in_nvim(paths)
  if not paths or vim.tbl_isempty(paths) then
    notify("No he encontrado rutas válidas que abrir.", vim.log.levels.WARN)
    return
  end

  local opened = 0
  for i, path in ipairs(paths) do
    if i == 1 then
      vim.cmd.edit(vim.fn.fnameescape(path))
    else
      vim.cmd.badd(vim.fn.fnameescape(path))
    end
    opened = opened + 1
  end
  notify(("Abierto(s) %d fichero(s)/directorio(s) en Neovim."):format(opened))
end

function M.handle_dropped_text(text, opts)
  opts = opts or {}
  local paths = M.paths_from_text(text)
  if #paths == 0 then return false end

  local bufnr = vim.api.nvim_get_current_buf()
  local ft = opts.filetype or vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if opts.force_avante or ft == "AvanteInput" or ft == "AvantePromptInput" then
    -- Let Avante/img-clip handle images as multimodal input. Non-image files
    -- are added as selected-files context instead of being pasted as text.
    if #paths == 1 and is_image(paths[1]) then
      local ok_clip, clipboard = pcall(require, "avante.clipboard")
      if ok_clip and clipboard.paste_image(paths[1]) then return true end
    end
    M.add_paths_to_avante(paths)
  else
    M.open_paths_in_nvim(paths)
  end

  return true
end

function M.setup_drag_drop()
  if vim.g.ai_context_drag_drop_setup then return end
  vim.g.ai_context_drag_drop_setup = true

  local previous_paste = vim.paste
  vim.paste = function(lines, phase)
    local text = table.concat(lines or {}, "\n")
    if M.handle_dropped_text(text) then return true end
    return previous_paste(lines, phase)
  end

  -- GUI/terminal UIs that expose a real <Drop> event can use this. It is
  -- harmless in terminals that only paste dropped paths through vim.paste.
  pcall(vim.keymap.set, { "n", "i", "v" }, "<Drop>", function()
    local dropped = vim.v.fname or vim.v.drop or ""
    if dropped ~= "" then M.handle_dropped_text(dropped) end
  end, { desc = "Abrir/añadir fichero arrastrado", silent = true })
end

function M.setup_commands()
  vim.api.nvim_create_user_command("AIAddFile", function(opts)
    M.add_paths_to_avante(opts.fargs)
  end, {
    nargs = "+",
    complete = "file",
    desc = "Añade fichero(s)/directorio(s) al contexto de Avante",
  })

  vim.api.nvim_create_user_command("AIAddBuffer", M.add_current_buffer, { desc = "Añade el buffer actual a Avante" })
  vim.api.nvim_create_user_command("AIAddBuffers", M.add_all_buffers, { desc = "Añade todos los buffers a Avante" })
  vim.api.nvim_create_user_command("AIAddQuickfix", M.add_quickfix, { desc = "Añade ficheros de quickfix a Avante" })
  vim.api.nvim_create_user_command("AIFilePicker", M.open_file_picker, { desc = "Selector de ficheros de Avante" })
  vim.api.nvim_create_user_command("AIOpenDrop", function(opts)
    local paths = #opts.fargs > 0 and opts.fargs or M.paths_from_text(opts.args)
    M.open_paths_in_nvim(paths)
  end, {
    nargs = "*",
    complete = "file",
    desc = "Abre en Neovim ficheros/directorios arrastrados o pasados como rutas",
  })
  vim.api.nvim_create_user_command("AIDropText", function(opts)
    if not M.handle_dropped_text(opts.args) then notify("El texto no contenía rutas existentes.", vim.log.levels.WARN) end
  end, {
    nargs = "+",
    complete = "file",
    desc = "Procesa texto/rutas como si vinieran de drag & drop",
  })
  vim.api.nvim_create_user_command("AIDropHelp", function()
    notify("Drag & drop: arrastra ficheros sobre Neovim. En buffers normales se abren; en AvanteInput se añaden como contexto. Si tu terminal no lo soporta, usa :AIOpenDrop ruta o :AIAddFile ruta.")
  end, { desc = "Ayuda rápida para drag&drop AI" })
end

function M.setup()
  M.setup_commands()
  M.setup_drag_drop()
end

return M

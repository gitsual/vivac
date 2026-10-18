local status_ok, spectre = pcall(require, "spectre")
if not status_ok then
  return
end

spectre.setup({
  color_devicons = true,
  open_cmd = 'vnew',
  live_update = true,
  line_sep_start = '┌─────────────────────────────────────────────────────────',
  result_padding = '│  ',
  line_sep = '└─────────────────────────────────────────────────────────',
  highlight = {
    ui = "String",
    search = "DiffChange",
    replace = "DiffDelete"
  },
  mapping = {
    ['toggle_line'] = {
      map = "dd",
      cmd = "<cmd>lua require('spectre').toggle_line()<CR>",
      desc = "toggle current item"
    },
    ['enter_file'] = {
      map = "<cr>",
      cmd = "<cmd>lua require('spectre.actions').select_entry()<CR>",
      desc = "goto current file"
    },
    ['send_to_qf'] = {
      map = "<leader>q",
      cmd = "<cmd>lua require('spectre.actions').send_to_qf()<CR>",
      desc = "send all items to quickfix"
    },
    ['replace_cmd'] = {
      map = "<leader>c",
      cmd = "<cmd>lua require('spectre.actions').replace_cmd()<CR>",
      desc = "input replace command"
    },
    ['show_option_menu'] = {
      map = "<leader>o",
      cmd = "<cmd>lua require('spectre').show_options()<CR>",
      desc = "show option"
    },
    ['run_current_replace'] = {
      map = "<leader>r",
      cmd = "<cmd>lua require('spectre.actions').run_current_replace()<CR>",
      desc = "replace current line"
    },
    ['run_replace'] = {
      map = "<leader>R",
      cmd = "<cmd>lua require('spectre.actions').run_replace()<CR>",
      desc = "replace all"
    },
    ['change_view_mode'] = {
      map = "<leader>v",
      cmd = "<cmd>lua require('spectre').change_view()<CR>",
      desc = "change result view mode"
    },
    ['toggle_live_update'] = {
      map = "tu",
      cmd = "<cmd>lua require('spectre').toggle_live_update()<CR>",
      desc = "update change when vim write file."
    },
    ['toggle_ignore_case'] = {
      map = "ti",
      cmd = "<cmd>lua require('spectre').change_options('ignore-case')<CR>",
      desc = "toggle ignore case"
    },
    ['toggle_ignore_hidden'] = {
      map = "th",
      cmd = "<cmd>lua require('spectre').change_options('hidden')<CR>",
      desc = "toggle search hidden"
    },
    ['resume_last_search'] = {
      map = "<leader>l",
      cmd = "<cmd>lua require('spectre').resume_last_search()<CR>",
      desc = "resume last search before close"
    },
    -- you can put your mapping here it only use normal mode
  },
})


return {
  defaults = { lazy = true },
  install = { colorscheme = { "nvchad" } },

  -- lazy.nvim applies this timeout to EVERY process it spawns, not just git:
  -- manage/process.lua falls back to `git.timeout * 1000` for build commands
  -- too. avante.nvim builds four Rust crates from source, which takes longer
  -- than two minutes on a four-core machine, so the default killed `make`
  -- mid-run. Its Makefile installs libraries with `cp`, which truncates the
  -- destination before rewriting it, so a kill there leaves a half-written
  -- shared object that the next `ffi.load` maps past its own end -- SIGBUS,
  -- with a stack trace that points at dlopen and says nothing about a build.
  git = { timeout = 600 },

  ui = {
    icons = {
      ft = "",
      lazy = "󰂠 ",
      loaded = "",
      not_loaded = "",
    },
  },

  performance = {
    rtp = {
      disabled_plugins = {
        "2html_plugin",
        "tohtml",
        "getscript",
        "getscriptPlugin",
        "gzip",
        "logipat",
        "netrw",
        "netrwPlugin",
        "netrwSettings",
        "netrwFileHandlers",
        "matchit",
        "tar",
        "tarPlugin",
        "rrhelper",
        "spellfile_plugin",
        "vimball",
        "vimballPlugin",
        "zip",
        "zipPlugin",
        "tutor",
        "rplugin",
        "syntax",
        "synmenu",
        "optwin",
        "compiler",
        "bugreport",
        "ftplugin",
      },
    },
  },
}

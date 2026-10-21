return {
  {
    "yetone/avante.nvim",
    event = "VeryLazy",
    lazy = false,
    version = false,
    build = "make",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "hrsh7th/nvim-cmp",
      "nvim-telescope/telescope.nvim",
      "nvim-tree/nvim-web-devicons", 
      {
        "HakonHarnes/img-clip.nvim",
        event = "VeryLazy",
        opts = {
          default = {
            embed_image_as_base64 = false,
            prompt_for_file_name = false,
            drag_and_drop = {
              enabled = true,
              insert_mode = true,
            },
            use_absolute_path = true,
          },
        },
      },
      {
        "MeanderingProgrammer/render-markdown.nvim",
        opts = {
          file_types = { "markdown", "Avante" },
        },
        ft = { "markdown", "Avante" },
      },
    },
    opts = {
      -- Los proxies CLI no implementan el tool-loop interno de Avante (attempt_completion).
      -- En modo agentic Avante relanza hasta 4 peticiones con recordatorios ocultos;
      -- legacy evita respuestas duplicadas cuando usamos codexcli/claudecli/geminicli.
      mode = vim.env.AVANTE_MODE or "legacy",
      -- Avante es la única interfaz IA dentro de Neovim. Los comandos custom
      -- (:AISelect, :AIAgent, :AICodex, :AIClaude, :AIGemini) ya no abren CLIs
      -- en terminal: todos cambian provider/modelo y usan la UI de Avante.
      -- Avante normalmente habla con providers HTTP/API, pero este setup usa
      -- proxies locales OpenAI-compatible hacia los CLIs ya logueados:
      -- codex 41337, claude 41338, gemini 41339. Así no hacen falta API keys.
      provider = vim.env.AVANTE_PROVIDER or "codexcli",
      providers = {
        codexcli = {
          __inherited_from = "openai",
          endpoint = vim.env.AVANTE_CODEX_ENDPOINT or "http://localhost:41337/v1",
          api_key_name = "",
          model = vim.env.AVANTE_CODEX_MODEL or vim.env.CODEX_MODEL or "gpt-5.5",
          timeout = 600000,
          context_window = 128000,
          disable_tools = true,
          extra_request_body = {
            temperature = 0.7,
          },
        },
        claudecli = {
          __inherited_from = "openai",
          endpoint = vim.env.AVANTE_CLAUDE_ENDPOINT or "http://localhost:41338/v1",
          api_key_name = "",
          model = vim.env.AVANTE_CLAUDE_MODEL or vim.env.CLAUDE_MODEL or "sonnet",
          timeout = 600000,
          context_window = 200000,
          disable_tools = true,
          extra_request_body = {
            temperature = 0.75,
          },
        },
        geminicli = {
          __inherited_from = "openai",
          endpoint = vim.env.AVANTE_GEMINI_ENDPOINT or "http://localhost:41339/v1",
          api_key_name = "",
          model = vim.env.AVANTE_GEMINI_MODEL or vim.env.GEMINI_MODEL or "gemini-2.5-flash",
          timeout = 600000,
          context_window = 1048576,
          disable_tools = true,
          extra_request_body = {
            temperature = 0.7,
          },
        },
        ollama = {
          endpoint = vim.env.AVANTE_OLLAMA_ENDPOINT or "http://localhost:11434",
          model = vim.env.AVANTE_OLLAMA_MODEL or "qwen2.5-coder:7b",
          timeout = 60000,
          context_window = 32768,
        },
        openai = {
          endpoint = "https://api.openai.com/v1",
          model = vim.env.AVANTE_OPENAI_MODEL or "gpt-5.5",
          timeout = 60000,
          context_window = 128000,
          extra_request_body = {
            temperature = 0.7,
            max_completion_tokens = 16384,
            reasoning_effort = "medium",
          },
        },
        gemini = {
          endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
          model = vim.env.AVANTE_GEMINI_MODEL or "gemini-3.1-pro-preview",
          timeout = 60000,
          context_window = 1048576,
          use_ReAct_prompt = true,
          extra_request_body = {
            generationConfig = {
              temperature = 0.7,
              maxOutputTokens = 65536,
            },
          },
        },
        claude = {
          endpoint = "https://api.anthropic.com",
          model = vim.env.AVANTE_ANTHROPIC_MODEL or "claude-opus-4-7",
          timeout = 60000,
          context_window = 200000,
          extra_request_body = {
            temperature = 0.75,
            max_tokens = 64000,
          },
        },
      },
      selector = {
        provider = "telescope",
      },
      behaviour = {
        support_paste_from_clipboard = true,
        auto_set_keymaps = true,
        auto_set_highlight_group = true,
        enable_token_counting = true,
        minimize_diff = true,
      },
      windows = {
        width = 38,
        input = {
          height = 10,
        },
        ask = {
          start_insert = true,
          border = "rounded",
        },
        edit = {
          start_insert = true,
          border = "rounded",
        },
      },
      shortcuts = {
        {
          name = "refactor",
          description = "Refactorizar manteniendo comportamiento",
          details = "Mejora legibilidad, estructura, nombres y manejo de errores sin cambiar la intención.",
          prompt = "Refactoriza este código manteniendo el comportamiento. Explica brevemente los cambios importantes.",
        },
        {
          name = "tests",
          description = "Generar o mejorar tests",
          details = "Cubre casos límite, errores y caminos principales.",
          prompt = "Genera o mejora tests para este código, incluyendo casos límite y errores. Usa el estilo del proyecto.",
        },
        {
          name = "review",
          description = "Revisión de código",
          details = "Busca bugs, seguridad, mantenibilidad y regresiones.",
          prompt = "Revisa este cambio como code review. Prioriza bugs reales, riesgos de seguridad, regresiones y mantenibilidad.",
        },
        {
          name = "explain",
          description = "Explicar código/contexto",
          details = "Explicación práctica y accionable.",
          prompt = "Explícame este código/contexto de forma práctica: qué hace, cómo fluye y qué debería vigilar.",
        },
      },
    },
    config = function(_, opts)
      require("avante").setup(opts)
      -- Compatibilidad defensiva para una carrera de Avante: durante WinNew puede
      -- consultar bordes con un winid ya cerrado y lanzar "Invalid window id".
      require("custom.configs.avante_compat").setup()
      require("custom.configs.ai_context").setup()
      require("custom.configs.ai_agents").setup()
    end,
  },
  {
    "nvim-pack/nvim-spectre",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    cmd = "Spectre",
    config = function()
      require "configs.spectre"
    end,
    keys = {
      { "<leader>ss", "<cmd>lua require('spectre').toggle()<CR>", desc = "Toggle Spectre" },
      { "<leader>sw", "<cmd>lua require('spectre').open_visual({select_word=true})<CR>", desc = "Search current word" },
      { "<leader>sp", "<cmd>lua require('spectre').open_file_search({select_word=true})<CR>", desc = "Search on current file" },
    },
  },
  {
    "stevearc/conform.nvim",
    config = function()
      require "configs.conform"
    end,
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      require("nvchad.configs.lspconfig").defaults()
      require "configs.lspconfig"
    end,
  },

  {
    "williamboman/mason.nvim",
    opts = {
      ensure_installed = {
        "lua-language-server",
        "typescript-language-server",
        "stylua",
        "html-lsp",
        "css-lsp",
        "prettier",
        "pyright",
      },
    },
  },

  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    lazy = false,
    build = ":TSUpdate",
    opts = {
      ensure_installed = {
        "vim",
        "lua",
        "vimdoc",
        "html",
        "css",
        "python",
        "typescript",
        "javascript",
        "tsx",
      },
    },
    config = function(_, opts)
      require("nvim-treesitter.configs").setup(opts)
      require("custom.configs.treesitter_compat").apply()
    end,
  },

  {
    "lewis6991/hover.nvim",
    config = function()
      require("hover").setup {
        init = function()
          -- Require providers
          require("hover.providers.lsp")
        end,
        preview_opts = {
          border = "rounded"
        },
        -- Whether the contents of a currently open hover window should be moved
        -- to a :h preview-window when pressing the hover keymap.
        preview_window = false,
        title = true
      }
    end,
  },

  {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-nvim-lua",
      "hrsh7th/cmp-buffer",
      {
        "FelipeLema/cmp-async-path",
        name = "cmp-async-path",
      },
      "saadparwaiz1/cmp_luasnip",
      {
        "L3MON4D3/LuaSnip",
        dependencies = "rafamadriz/friendly-snippets",
        config = function()
          require("luasnip.loaders.from_vscode").lazy_load()
        end,
      },
    },
    opts = function()
      return require "custom.configs.cmp"
    end,
  },

  {
    "L3MON4D3/LuaSnip",
    dependencies = {
      "rafamadriz/friendly-snippets",
      config = function()
        require("luasnip.loaders.from_vscode").lazy_load()
      end,
    },
    opts = {
      history = true,
      delete_check_events = "TextChanged",
    },
  },

  {
    "potamides/pantran.nvim",
    lazy = false,
    config = function()
      require("pantran").setup({
        default_engine = "argos",
        engines = {
          argos = {
            default_source = "en",
            default_target = "es",
          },
        },
      })
    end,
  },


}

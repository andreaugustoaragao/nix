{ config, pkgs, useDms ? false, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    
    plugins = with pkgs.vimPlugins; [
      # Core lazy.nvim for plugin management
      lazy-nvim
      
      # Essential plugins that need to be available immediately
      kanagawa-nvim  # Colorscheme needs to be available at startup
      plenary-nvim   # Many plugins depend on this
    ];
    
    extraLuaConfig = ''
      -- Bootstrap lazy.nvim
      local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
      if not vim.uv.fs_stat(lazypath) then
        vim.fn.system({
          "git",
          "clone",
          "--filter=blob:none",
          "https://github.com/folke/lazy.nvim.git",
          "--branch=stable",
          lazypath,
        })
      end
      vim.opt.rtp:prepend(lazypath)
      
      -- Configure leader keys before lazy.nvim setup
      vim.g.mapleader = " "
      vim.g.maplocalleader = "\\"
      
      -- Track startup time from the very beginning
      vim.g.start_time = vim.uv.hrtime()
      
      -- Basic Neovim options
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.expandtab = true
      vim.opt.shiftwidth = 2
      vim.opt.tabstop = 2
      vim.opt.softtabstop = 2
      vim.opt.smartindent = true
      vim.opt.autoindent = true
      vim.opt.wrap = false
      
      -- GUI font configuration for Neovide
      if vim.g.neovide then
        vim.opt.guifont = "CaskaydiaMono Nerd Font:h12"
        -- Neovide-specific settings
        vim.g.neovide_scale_factor = 1.0
        vim.g.neovide_opacity = 0.0  -- For unified transparency
        vim.g.transparency = 0.95    -- Set transparency level
        vim.g.neovide_background_color = "#1f1f28" .. string.format("%x", math.floor(255 * (vim.g.transparency or 0.95)))
      end
      vim.opt.ignorecase = true
      vim.opt.smartcase = true
      vim.opt.hlsearch = false
      vim.opt.incsearch = true
      vim.opt.termguicolors = true
      vim.opt.scrolloff = 8
      vim.opt.sidescrolloff = 8
      vim.opt.signcolumn = "yes"
      vim.opt.updatetime = 200
      vim.opt.timeoutlen = 300
      vim.opt.clipboard = "unnamedplus"
      vim.opt.splitbelow = true
      vim.opt.splitright = true
      vim.opt.mouse = "a"
      vim.opt.cursorline = true
      vim.opt.undofile = true

      -- Hide the EndOfBuffer "~" markers, give the window-split
      -- separator a solid Kanagawa-violet line (replaces what
      -- colorful-winsep.nvim used to render).
      vim.opt.fillchars = { eob = " ", vert = "│" }

      -- Auto-reload files when changed externally (silent).
      --
      -- Uses libuv's filesystem-event API (inotify on Linux) rather
      -- than polling on FocusGained/BufEnter/CursorHold. Each open
      -- buffer attaches a kernel watcher to its file; on any modify
      -- event nvim runs :checktime in that buffer's context, which
      -- reloads the buffer when autoread is on and the buffer is
      -- clean. Dirty buffers still get the FileChangedShell prompt.
      vim.opt.autoread = true

      local function watch_buffer(buf)
        local file = vim.api.nvim_buf_get_name(buf)
        if file == "" or vim.fn.filereadable(file) == 0 then
          return
        end

        local handle = vim.uv.new_fs_event()
        if not handle then
          return
        end

        local function on_event(err)
          if err or not vim.api.nvim_buf_is_valid(buf) then
            if not handle:is_closing() then handle:close() end
            return
          end
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("checktime")
          end)
          -- Editors that save via "write-temp + rename" change the
          -- inode, which kills the original watch; re-arm on the
          -- (new) inode each time we fire.
          if not handle:is_closing() then
            handle:stop()
            handle:start(file, {}, vim.schedule_wrap(on_event))
          end
        end

        handle:start(file, {}, vim.schedule_wrap(on_event))

        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
          buffer = buf,
          callback = function()
            if not handle:is_closing() then handle:close() end
          end,
        })
      end

      vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
        callback = function(ev) watch_buffer(ev.buf) end,
      })

      -- Folding configuration (prefer LSP, fallback to treesitter)
      vim.opt.foldmethod = "expr"
      vim.opt.foldexpr = "v:lua.vim.lsp.foldexpr()"
      vim.opt.foldenable = true
      vim.opt.foldlevel = 99  -- Start with all folds open
      vim.opt.foldlevelstart = 99
      vim.opt.foldcolumn = "1"  -- Show fold column
      
      -- Fallback to treesitter folding if LSP folding is not available
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client and client.server_capabilities.foldingRangeProvider then
            -- LSP supports folding, keep LSP folding
            vim.opt_local.foldexpr = "v:lua.vim.lsp.foldexpr()"
          else
            -- LSP doesn't support folding, use treesitter
            vim.opt_local.foldexpr = "nvim_treesitter#foldexpr()"
          end
        end,
      })
      
      -- Folding keymaps
      vim.keymap.set("n", "zR", "zR", { desc = "Open all folds" })
      vim.keymap.set("n", "zM", "zM", { desc = "Close all folds" })
      vim.keymap.set("n", "zr", "zr", { desc = "Reduce fold level" })
      vim.keymap.set("n", "zm", "zm", { desc = "Increase fold level" })
      vim.keymap.set("n", "za", "za", { desc = "Toggle fold" })
      vim.keymap.set("n", "zo", "zo", { desc = "Open fold" })
      vim.keymap.set("n", "zc", "zc", { desc = "Close fold" })
      
      -- Setup lazy.nvim
      require("lazy").setup({
        rocks = {
          enabled = true,
          root = vim.fn.stdpath("data") .. "/lazy-rocks",
          server = "https://luarocks.org/", 
        },
        spec = {
          -- Import only specific LazyVim plugins we want, not all
          -- { "LazyVim/LazyVim", import = "lazyvim.plugins" },

          -- Auto-import any plugin spec in ~/.config/nvim/lua/plugins/.
          -- DMS writes its matugen base16 colorscheme there as
          -- dankcolors.lua when matugenTemplateNeovim is enabled.
          { import = "plugins" },
          
          -- Icon support (load early for better keymap support)
          {
            "nvim-tree/nvim-web-devicons",
            lazy = false,
            config = function()
              require("nvim-web-devicons").setup({
                override_by_filename = {
                  [".gitignore"] = {
                    icon = "",
                    color = "#f1502f",
                    name = "Gitignore"
                  }
                },
                color_icons = true,
                default = true,
              })
            end,
          },
          
          -- Alternative modern icon provider
          {
            "echasnovski/mini.icons",
            event = "VeryLazy",
            opts = {},
            init = function()
              ---@diagnostic disable-next-line: duplicate-set-field
              package.preload["nvim-web-devicons"] = function()
                require("mini.icons").mock_nvim_web_devicons()
                return package.loaded["nvim-web-devicons"]
              end
            end,
          },
          
          -- Colorscheme (load immediately)
          {
            "rebelot/kanagawa.nvim",
            priority = 1000,
            config = function()
              require('kanagawa').setup({
                compile = false,
                undercurl = true,
                commentStyle = { italic = true },
                functionStyle = {},
                keywordStyle = { italic = true},
                statementStyle = { bold = true },
                typeStyle = {},
                transparent = false,
                dimInactive = false,
                terminalColors = true,
                colors = {
                  palette = {},
                  theme = { wave = {}, lotus = {}, dragon = {}, all = {} },
                },
                overrides = function(colors)
                  return {}
                end,
                theme = "wave",
                background = {
                  dark = "wave",
                  light = "lotus"
                },
              })
              -- DMS's matugen integration writes a base16 plugin spec to
              -- lua/plugins/dankcolors.lua. When present, let it own the
              -- palette; otherwise fall back to kanagawa.
              local dms_colors = vim.fn.stdpath("config") .. "/lua/plugins/dankcolors.lua"
              if vim.fn.filereadable(dms_colors) ~= 1 then
                vim.cmd("colorscheme kanagawa")
              end
            end,
          },
          
          -- alpha-nvim was replaced by snacks.dashboard on 2026-05-01.
          { "goolord/alpha-nvim", enabled = false },

          -- snacks.nvim — folke's QoL collection. Replaces alpha
          -- (dashboard), telescope (picker), nvim-tree (explorer),
          -- and adds bigfile/notifier/scroll/scratch out of the box.
          -- Loads at startup so dashboard appears on bare `nvim`.
          {
            "folke/snacks.nvim",
            priority = 1000,
            lazy = false,
            ---@type snacks.Config
            opts = {
              bigfile = { enabled = true }, -- auto-disables TS/LSP/syntax on >1.5MB files
              notifier = { enabled = true, timeout = 3000 },
              quickfile = { enabled = true },
              statuscolumn = { enabled = true },
              scroll = { enabled = true },
              indent = { enabled = true },
              picker = {
                enabled = true,
                ui_select = true, -- replace vim.ui.select with snacks picker
                layout = {
                  preset = "default",
                  layout = { position = "float" },
                },
              },
              explorer = { enabled = true, replace_netrw = true },

              dashboard = {
                enabled = true,
                preset = {
                  -- Custom ASCII art header (Kanagawa-inspired wave).
                  header = table.concat({
                    "",
                    "  ███╗   ██╗███████╗ ██████╗ ██╗   ██╗██╗███╗   ███╗ ",
                    "  ████╗  ██║██╔════╝██╔═══██╗██║   ██║██║████╗ ████║ ",
                    "  ██╔██╗ ██║█████╗  ██║   ██║██║   ██║██║██╔████╔██║ ",
                    "  ██║╚██╗██║██╔══╝  ██║   ██║╚██╗ ██╔╝██║██║╚██╔╝██║ ",
                    "  ██║ ╚████║███████╗╚██████╔╝ ╚████╔╝ ██║██║ ╚═╝ ██║ ",
                    "  ╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚═╝     ╚═╝ ",
                    "",
                    "           🌊 Kanagawa Theme - Like the Great Wave    ",
                    "",
                  }, "\n"),
                  keys = {
                    { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
                    { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
                    { icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('grep')" },
                    { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
                    { icon = " ", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', { cwd = vim.fn.stdpath('config') })" },
                    { icon = " ", key = "s", desc = "Restore Session", section = "session" },
                    { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
                    { icon = " ", key = "q", desc = "Quit", action = ":qa" },
                  },
                },
                sections = {
                  { section = "header" },
                  { section = "keys", gap = 1, padding = 1 },
                  { section = "startup" },
                  {
                    text = {
                      { "", hl = "Comment" },
                      { "The Great Wave off Kanagawa inspires this colorful journey", hl = "SnacksDashboardFooter" },
                      { "", hl = "Comment" },
                      { "~ Katsushika Hokusai ~", hl = "SnacksDashboardFooter" },
                    },
                    align = "center",
                  },
                },
              },

              styles = {
                notification = { wo = { wrap = true } },
              },
            },
            keys = {
              -- Picker (replaces telescope)
              { "<leader>ff", function() Snacks.picker.files() end,        desc = "Find Files" },
              { "<leader>fg", function() Snacks.picker.grep() end,         desc = "Live Grep" },
              { "<leader>fb", function() Snacks.picker.buffers() end,      desc = "Buffers" },
              { "<leader>fh", function() Snacks.picker.help() end,         desc = "Help Tags" },
              { "<leader>fr", function() Snacks.picker.recent() end,       desc = "Recent Files" },
              { "<leader>fc", function() Snacks.picker.command_history() end, desc = "Command History" },
              { "<leader>fs", function() Snacks.picker.lsp_symbols() end,  desc = "Symbols" },
              { "<leader>fd", function() Snacks.picker.diagnostics() end,  desc = "Diagnostics" },
              -- Explorer (replaces nvim-tree)
              { "<leader>e",  function() Snacks.explorer() end,             desc = "Toggle file explorer" },
              -- Notifications
              { "<leader>n",  function() Snacks.notifier.show_history() end, desc = "Notification history" },
            },
            init = function()
              -- Use snacks for vim.notify so toasts get the styled UI.
              vim.api.nvim_create_autocmd("User", {
                pattern = "VeryLazy",
                callback = function()
                  vim.notify = Snacks.notifier.notify
                end,
              })

              -- Dashboard header palette (Kanagawa colours).
              vim.api.nvim_create_autocmd("ColorScheme", {
                pattern = "*",
                callback = function()
                  vim.api.nvim_set_hl(0, "SnacksDashboardHeader", { fg = "#957fb8" })
                  vim.api.nvim_set_hl(0, "SnacksDashboardKey",    { fg = "#7e9cd8" })
                  vim.api.nvim_set_hl(0, "SnacksDashboardDesc",   { fg = "#dcd7ba" })
                  vim.api.nvim_set_hl(0, "SnacksDashboardFooter", { fg = "#727169", italic = true })
                end,
              })
            end,
          },
          
          -- telescope.nvim was replaced by snacks.picker on 2026-05-01.
          { "nvim-telescope/telescope.nvim", enabled = false },
          { "nvim-telescope/telescope-fzf-native.nvim", enabled = false },
          
          -- Completion setup — blink.cmp replaced the nvim-cmp stack
          -- (cmp-nvim-lsp, cmp-buffer, cmp-path, cmp-cmdline,
          -- cmp_luasnip, cmp-nvim-lua, cmp-nvim-lsp-signature-help,
          -- cmp-calc, cmp-spell, cmp-emoji, cmp-dictionary) on
          -- 2026-05-01. blink ships LSP/buffer/path/snippet/cmdline
          -- as built-in providers and a Rust-backed fuzzy matcher.
          { "hrsh7th/nvim-cmp", enabled = false },
          { "hrsh7th/cmp-nvim-lsp", enabled = false },
          { "hrsh7th/cmp-buffer", enabled = false },
          { "hrsh7th/cmp-path", enabled = false },
          { "hrsh7th/cmp-cmdline", enabled = false },
          { "saadparwaiz1/cmp_luasnip", enabled = false },
          { "hrsh7th/cmp-nvim-lua", enabled = false },
          { "hrsh7th/cmp-nvim-lsp-signature-help", enabled = false },
          { "hrsh7th/cmp-calc", enabled = false },
          { "f3fora/cmp-spell", enabled = false },
          { "hrsh7th/cmp-emoji", enabled = false },
          { "uga-rosa/cmp-dictionary", enabled = false },

          {
            "L3MON4D3/LuaSnip",
            build = function()
              if vim.fn.executable("make") == 1 then
                return "make install_jsregexp"
              end
              return nil
            end,
            dependencies = { "rafamadriz/friendly-snippets" },
            config = function()
              require("luasnip.loaders.from_vscode").lazy_load()
            end,
          },

          {
            "saghen/blink.cmp",
            -- pulls a tagged release with the prebuilt Rust fuzzy
            -- matcher binary, so no cargo build needed at install.
            version = "*",
            event = "InsertEnter",
            dependencies = { "L3MON4D3/LuaSnip" },
            ---@module "blink.cmp"
            ---@type blink.cmp.Config
            opts = {
              keymap = {
                preset = "default",
                ["<CR>"] = { "accept", "fallback" },
                ["<Tab>"] = { "select_next", "snippet_forward", "fallback" },
                ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
                ["<C-Space>"] = { "show", "show_documentation", "hide_documentation" },
                ["<C-e>"] = { "hide", "fallback" },
                ["<C-b>"] = { "scroll_documentation_up", "fallback" },
                ["<C-f>"] = { "scroll_documentation_down", "fallback" },
              },
              snippets = { preset = "luasnip" },
              completion = {
                accept = { auto_brackets = { enabled = true } },
                documentation = {
                  auto_show = true,
                  auto_show_delay_ms = 200,
                  window = { border = "rounded" },
                },
                menu = {
                  border = "rounded",
                  draw = {
                    treesitter = { "lsp" },
                    columns = {
                      { "kind_icon", "label", "label_description", gap = 1 },
                      { "kind" },
                    },
                  },
                },
                ghost_text = { enabled = true },
                list = { selection = { preselect = true, auto_insert = false } },
              },
              signature = { enabled = true, window = { border = "rounded" } },
              sources = {
                default = { "lsp", "path", "snippets", "buffer" },
                providers = {
                  buffer = {
                    -- mimic old cmp-buffer keyword_length=3 behaviour
                    min_keyword_length = 3,
                  },
                },
              },
              fuzzy = { implementation = "prefer_rust_with_warning" },
              cmdline = {
                keymap = { preset = "inherit" },
                completion = { menu = { auto_show = true } },
              },
              appearance = {
                use_nvim_cmp_as_default = false,
                nerd_font_variant = "mono",
              },
            },
            opts_extend = { "sources.default" },
          },


          -- LSP Configuration. Kept nvim-lspconfig as a dependency
          -- because it ships the per-server defaults (filetypes,
          -- root markers, default cmd) that vim.lsp.config layers on
          -- top of. Activation has moved to a single vim.lsp.enable
          -- call below — no more per-filetype autocmds.
          {
            "neovim/nvim-lspconfig",
            event = { "BufReadPre", "BufNewFile" },
            dependencies = { "saghen/blink.cmp" },
            config = function()
              -- blink.cmp exposes its capabilities via a helper so
              -- the LSP knows which client features are supported
              -- (snippet expansion, completion item resolution, etc).
              local capabilities = require("blink.cmp").get_lsp_capabilities()

              -- Enable file watching capabilities (important for project-wide changes)
              capabilities.workspace = capabilities.workspace or {}
              capabilities.workspace.didChangeWatchedFiles = {
                dynamicRegistration = true,
                relativePatternSupport = true,
              }
              
              -- Configure LSP servers using the new vim.lsp.config API (Neovim 0.11+)
              
              -- Nix LSP
              vim.lsp.config('nil_ls', {
                capabilities = capabilities,
              })
              
              -- Bash LSP  
              vim.lsp.config('bashls', {
                capabilities = capabilities,
              })
              
              -- Markdown LSP
              vim.lsp.config('marksman', {
                capabilities = capabilities,
              })
              
              -- Python LSP
              vim.lsp.config('pyright', {
                capabilities = capabilities,
                settings = {
                  python = {
                    analysis = {
                      autoSearchPaths = true,
                      useLibraryCodeForTypes = true,
                      diagnosticMode = "workspace",
                    },
                  },
                },
              })
              
              -- Go LSP
              vim.lsp.config('gopls', {
                capabilities = capabilities,
                settings = {
                  gopls = {
                    gofumpt = true,
                    codelenses = {
                      gc_details = false,
                      generate = true,
                      regenerate_cgo = true,
                      run_govulncheck = true,
                      test = true,
                      tidy = true,
                      upgrade_dependency = true,
                      vendor = true,
                    },
                    hints = {
                      assignVariableTypes = true,
                      compositeLiteralFields = true,
                      compositeLiteralTypes = true,
                      constantValues = true,
                      functionTypeParameters = true,
                      parameterNames = true,
                      rangeVariableTypes = true,
                    },
                    analyses = {
                      nilness = true,
                      unusedparams = true,
                      unusedwrite = true,
                      useany = true,
                    },
                  },
                },
              })
              
              -- TypeScript/JavaScript LSP with enhanced configuration
              vim.lsp.config('ts_ls', {
                capabilities = capabilities,
                init_options = {
                  preferences = {
                    disableSuggestions = false,
                    quotePreference = "double",
                    includeCompletionsForModuleExports = true,
                    includeCompletionsForImportStatements = true,
                    includeCompletionsWithSnippetText = true,
                    includeAutomaticOptionalChainCompletions = true,
                  },
                },
                settings = {
                  typescript = {
                    inlayHints = {
                      includeInlayParameterNameHints = "all",
                      includeInlayParameterNameHintsWhenArgumentMatchesName = false,
                      includeInlayFunctionParameterTypeHints = true,
                      includeInlayVariableTypeHints = true,
                      includeInlayVariableTypeHintsWhenTypeMatchesName = false,
                      includeInlayPropertyDeclarationTypeHints = true,
                      includeInlayFunctionLikeReturnTypeHints = true,
                      includeInlayEnumMemberValueHints = true,
                    },
                    suggest = {
                      includeCompletionsForModuleExports = true,
                    },
                    preferences = {
                      importModuleSpecifier = "relative",
                      includePackageJsonAutoImports = "auto",
                    },
                  },
                  javascript = {
                    inlayHints = {
                      includeInlayParameterNameHints = "all",
                      includeInlayParameterNameHintsWhenArgumentMatchesName = false,
                      includeInlayFunctionParameterTypeHints = true,
                      includeInlayVariableTypeHints = true,
                      includeInlayVariableTypeHintsWhenTypeMatchesName = false,
                      includeInlayPropertyDeclarationTypeHints = true,
                      includeInlayFunctionLikeReturnTypeHints = true,
                      includeInlayEnumMemberValueHints = true,
                    },
                    suggest = {
                      includeCompletionsForModuleExports = true,
                    },
                  },
                },
              })
              
              -- Java LSP
              vim.lsp.config('jdtls', {
                capabilities = capabilities,
              })

              -- Rust LSP
              vim.lsp.config('rust_analyzer', {
                capabilities = capabilities,
                settings = {
                  ["rust-analyzer"] = {
                    cargo = {
                      allFeatures = true,
                      loadOutDirsFromCheck = true,
                      buildScripts = {
                        enable = true,
                      },
                    },
                    checkOnSave = {
                      command = "clippy",
                      extraArgs = { "--all", "--", "-W", "clippy::all" },
                    },
                    procMacro = {
                      enable = true,
                      ignored = {
                        ["async-trait"] = { "async_trait" },
                        ["napi-derive"] = { "napi" },
                        ["async-recursion"] = { "async_recursion" },
                      },
                    },
                    inlayHints = {
                      bindingModeHints = {
                        enable = false,
                      },
                      chainingHints = {
                        enable = true,
                      },
                      closingBraceHints = {
                        enable = true,
                        minLines = 25,
                      },
                      closureReturnTypeHints = {
                        enable = "never",
                      },
                      lifetimeElisionHints = {
                        enable = "never",
                        useParameterNames = false,
                      },
                      maxLength = 25,
                      parameterHints = {
                        enable = true,
                      },
                      reborrowHints = {
                        enable = "never",
                      },
                      renderColons = true,
                      typeHints = {
                        enable = true,
                        hideClosureInitialization = false,
                        hideNamedConstructor = false,
                      },
                    },
                  },
                },
              })

              -- One-shot enable for all configured servers. Each
              -- server's filetypes/root_dir come from nvim-lspconfig's
              -- defaults (in its lsp/<name>.lua files), layered with
              -- the overrides set via vim.lsp.config above. nvim
              -- attaches each server only when a matching filetype is
              -- opened — no per-filetype autocmd needed.
              vim.lsp.enable({
                "nil_ls",
                "bashls",
                "marksman",
                "pyright",
                "gopls",
                "ts_ls",
                "jdtls",
                "rust_analyzer",
              })

              -- LSP keybindings + inlay-hint toggle. Inlay hints are
              -- configured per-server above (gopls/ts_ls/pyright/
              -- rust_analyzer) but the runtime toggle still needs
              -- vim.lsp.inlay_hint.enable() to actually show them.
              vim.api.nvim_create_autocmd("LspAttach", {
                group = vim.api.nvim_create_augroup("UserLspConfig", {}),
                callback = function(ev)
                  local opts = { buffer = ev.buf }
                  vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
                  vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
                  vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
                  vim.keymap.set("n", "gi", vim.lsp.buf.implementation, opts)
                  vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, opts)
                  vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
                  vim.keymap.set({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, opts)
                  vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
                  -- <leader>cf is owned by conform.nvim (with
                  -- lsp_fallback), so no LSP-specific format binding
                  -- here — keeps the keymap unambiguous.

                  local client = vim.lsp.get_client_by_id(ev.data.client_id)
                  if client and client.server_capabilities.inlayHintProvider then
                    vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
                  end
                end,
              })

              -- <leader>ti: global inlay-hint toggle, applied to all buffers.
              vim.keymap.set("n", "<leader>ti", function()
                vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
              end, { desc = "Toggle inlay hints" })

              -- Format-on-save is owned by conform.nvim (with
              -- lsp_fallback), so no LSP-driven BufWritePre here —
              -- otherwise the buffer formats twice per save.
            end,
          },
          
          -- nvim-tree replaced by snacks.explorer on 2026-05-01.
          -- (<leader>e keymap is defined on the snacks.nvim spec.)
          { "nvim-tree/nvim-tree.lua", enabled = false },
          
          -- Status line configuration (advanced setup from nix-config)
          {
            "nvim-lualine/lualine.nvim",
            event = "VeryLazy",
            dependencies = {
              "nvim-tree/nvim-web-devicons",
            },
            init = function()
              vim.g.lualine_laststatus = vim.o.laststatus
              if vim.fn.argc(-1) > 0 then
                -- set an empty statusline till lualine loads
                vim.o.statusline = " "
              else
                -- hide the statusline on the starter page
                vim.o.laststatus = 0
              end
            end,
            opts = function()
              -- PERF: we don't need this lualine require madness 🤷
              local lualine_require = require("lualine_require")
              lualine_require.require = require

              -- Icon definitions from nix-config
              local icons = {
                misc = {
                  dots = "󰇘",
                },
                diagnostics = {
                  Error = " ",
                  Warn = " ",
                  Hint = " ",
                  Info = " ",
                },
                git = {
                  added = " ",
                  modified = " ",
                  removed = " ",
                },
              }

              vim.o.laststatus = vim.g.lualine_laststatus

              return {
                options = {
                  theme = "auto", -- derive from whatever colorscheme is active (kanagawa fallback OR DMS's base16/dankcolors)
                  globalstatus = true,
                  component_separators = { left = "", right = "" },
                  section_separators = { left = "", right = "" },
                  disabled_filetypes = {
                    statusline = { "dashboard", "alpha", "starter", "snacks_dashboard" },
                    winbar = { "help", "alpha", "dashboard", "snacks_dashboard", "snacks_layout_box", "NvimTree", "Trouble", "starter" },
                  },
                  disabled_buftypes = {
                    "quickfix",
                    "prompt",
                  },
                  ignore_focus = {
                    "NvimTree",
                    "snacks_layout_box",
                  },
                },
                sections = {
                  lualine_a = { "mode" },
                  lualine_b = { "branch" },
                  lualine_c = {
                    {
                      "diagnostics",
                      always_visible = true,
                      symbols = {
                        error = icons.diagnostics.Error,
                        warn = icons.diagnostics.Warn,
                        info = icons.diagnostics.Info,
                        hint = icons.diagnostics.Hint,
                      },
                    },
                    { "filetype", icon_only = true, separator = "", padding = { left = 1, right = 0 } },
                    {
                      "filename",
                      file_status = true,
                      newfile_status = true,
                      path = 1, -- Relative path
                    },
                  },
                  lualine_x = {
                    -- Lazy.nvim updates
                    {
                      require("lazy.status").updates,
                      cond = require("lazy.status").has_updates,
                      color = { fg = "#ff9e64" },
                    },
                    -- Git diff
                    {
                      "diff",
                      symbols = {
                        added = icons.git.added,
                        modified = icons.git.modified,
                        removed = icons.git.removed,
                      },
                      source = function()
                        local gitsigns = vim.b.gitsigns_status_dict
                        if gitsigns then
                          return {
                            added = gitsigns.added,
                            modified = gitsigns.changed,
                            removed = gitsigns.removed,
                          }
                        end
                      end,
                    },
                  },
                  lualine_y = {
                    { "encoding" },
                    {
                      "fileformat",
                      symbols = {
                        unix = "󰌽", -- Unix/Linux symbol
                        dos = "󰍲", -- Windows/DOS symbol  
                        mac = "󰀵", -- macOS symbol
                      },
                    },
                  },
                  lualine_z = {
                    { "progress", separator = " ", padding = { left = 1, right = 0 } },
                    { "location", padding = { left = 0, right = 1 } },
                  },
                },
                extensions = { "lazy", "quickfix" },
              }
            end,
          },
          
          -- Treesitter (lazy-loaded based on filetype)
          {
            "nvim-treesitter/nvim-treesitter",
            build = ":TSUpdate",
            event = { "BufReadPost", "BufNewFile" },
            config = function()
              require("nvim-treesitter.configs").setup({
                ensure_installed = {
                  "nix", "bash", "markdown", "markdown_inline", "lua", "vim", "vimdoc",
                  "python", "go", "rust", "javascript", "typescript", "tsx", "json", "yaml",
                  "java", "dockerfile", "terraform", "toml"
                },
                sync_install = false,
                -- Don't silently install grammars at runtime; rely on
                -- the explicit ensure_installed list above so the closure
                -- stays reproducible.
                auto_install = false,
                highlight = {
                  enable = true,
                  additional_vim_regex_highlighting = false,
                },
                indent = {
                  enable = true,
                },
                -- Enable folding based on treesitter
                fold = {
                  enable = true,
                },
              })
            end,
          },
          
          -- Git integration (lazy-loaded when in git repo)
          {
            "lewis6991/gitsigns.nvim",
            opts = {},
          },
          
          -- nvim-autopairs replaced by mini.pairs on 2026-05-01.
          { "windwp/nvim-autopairs", enabled = false },

          -- mini.pairs — treesitter-aware bracket/quote auto-pairs.
          -- Lighter than nvim-autopairs and integrates cleanly with
          -- blink.cmp's accept/auto_brackets handling.
          {
            "echasnovski/mini.pairs",
            event = "InsertEnter",
            opts = {
              modes = { insert = true, command = true, terminal = false },
              -- skip autopair when inside a string/comment/regex
              skip_ts = { "string" },
              -- skip when next char is a closing bracket (avoid ((x))))
              skip_unbalanced = true,
              markdown = true,
            },
          },

          -- flash.nvim — s/S motions for fast cursor jumps. Replaces
          -- the leap/hop family with a tighter native-feel design.
          {
            "folke/flash.nvim",
            event = "VeryLazy",
            opts = {},
            keys = {
              { "s",     mode = { "n", "x", "o" }, function() require("flash").jump() end,        desc = "Flash" },
              { "S",     mode = { "n", "x", "o" }, function() require("flash").treesitter() end,  desc = "Flash Treesitter" },
              { "r",     mode = "o",                function() require("flash").remote() end,      desc = "Remote Flash" },
              { "R",     mode = { "o", "x" },       function() require("flash").treesitter_search() end, desc = "Treesitter Search" },
              { "<C-s>", mode = { "c" },            function() require("flash").toggle() end,      desc = "Toggle Flash Search" },
            },
          },

          -- oil.nvim — edit directories as buffers (rename/move/delete
          -- via :w). Complements snacks.explorer for keyboard-driven
          -- batch filesystem ops.
          {
            "stevearc/oil.nvim",
            cmd = { "Oil" },
            keys = {
              { "-", "<cmd>Oil<cr>", desc = "Open parent directory in Oil" },
            },
            opts = {
              default_file_explorer = false, -- snacks.explorer keeps the netrw-replace role
              view_options = { show_hidden = true },
              keymaps = {
                ["g?"] = "actions.show_help",
                ["<CR>"] = "actions.select",
                ["<C-s>"] = { "actions.select", opts = { vertical = true } },
                ["<C-h>"] = { "actions.select", opts = { horizontal = true } },
                ["<C-c>"] = "actions.close",
                ["<C-l>"] = "actions.refresh",
                ["-"] = "actions.parent",
                ["_"] = "actions.open_cwd",
                ["`"] = "actions.cd",
                ["~"] = { "actions.cd", opts = { scope = "tab" } },
                ["gs"] = "actions.change_sort",
                ["gx"] = "actions.open_external",
                ["g."] = "actions.toggle_hidden",
                ["g\\"] = "actions.toggle_trash",
              },
            },
          },
          
          -- Which-key (lazy-loaded on key press)  
          {
            "folke/which-key.nvim",
            opts = {
              preset = "modern",
            },
          },
          
          -- Mason (disabled on NixOS - we use Nix packages)
          { "williamboman/mason.nvim", enabled = false },
          { "williamboman/mason-lspconfig.nvim", enabled = false },
          
          -- Disable unwanted colorschemes (we only want Kanagawa)
          { "folke/tokyonight.nvim", enabled = false },
          { "catppuccin/nvim", name = "catppuccin", enabled = false },
          
          -- colorful-winsep.nvim disabled on 2026-05-01: native
          -- WinSeparator highlight + fillchars.vert give the same
          -- effect with no plugin (set up after lazy.setup, see below).
          { "nvim-zh/colorful-winsep.nvim", enabled = false },
          
          -- Advanced Markdown Editing Plugins
          --
          -- markdown-preview.nvim was disabled on 2026-05-01:
          -- render-markdown.nvim (below) provides in-buffer rendering,
          -- which covers the same use case without spawning a node
          -- server / opening a browser tab. <leader>mp is now free.
          { "iamcco/markdown-preview.nvim", enabled = false },


          {
            "MeanderingProgrammer/render-markdown.nvim",
            ft = { "markdown" },
            dependencies = { 
              "nvim-treesitter/nvim-treesitter", 
              "nvim-tree/nvim-web-devicons" 
            },
            opts = {
              heading = {
                enabled = true,
                sign = true,
                position = "overlay",
                icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " },
                backgrounds = {
                  "RenderMarkdownH1Bg",
                  "RenderMarkdownH2Bg", 
                  "RenderMarkdownH3Bg",
                  "RenderMarkdownH4Bg",
                  "RenderMarkdownH5Bg",
                  "RenderMarkdownH6Bg",
                },
                foregrounds = {
                  "RenderMarkdownH1",
                  "RenderMarkdownH2",
                  "RenderMarkdownH3", 
                  "RenderMarkdownH4",
                  "RenderMarkdownH5",
                  "RenderMarkdownH6",
                },
              },
              code = {
                enabled = true,
                sign = false,
                style = "full",
                position = "left",
                language_pad = 0,
                disable_background = { "diff" },
                width = "full",
                left_pad = 0,
                right_pad = 0,
                min_width = 0,
                border = "thin",
              },
              dash = {
                enabled = true,
                icon = "─",
                width = "full",
              },
              bullet = {
                enabled = true,
                icons = { "●", "○", "◆", "◇" },
              },
              checkbox = {
                enabled = true,
                unchecked = {
                  icon = "󰄱 ",
                  highlight = "RenderMarkdownUnchecked",
                },
                checked = {
                  icon = "󰱒 ",
                  highlight = "RenderMarkdownChecked", 
                },
              },
              quote = {
                enabled = true,
                icon = "▋",
                repeat_linebreak = false,
              },
              pipe_table = {
                enabled = true,
                style = "full",
                cell = "padded",
                border = {
                  "┌", "┬", "┐",
                  "├", "┼", "┤", 
                  "└", "┴", "┘",
                  "│", "─",
                },
                alignment_indicator = "━",
                head = "RenderMarkdownTableHead",
                row = "RenderMarkdownTableRow",
                filler = "RenderMarkdownTableFill",
              },
              callout = {
                note = { raw = "[!NOTE]", rendered = "󰋽 Note", highlight = "RenderMarkdownInfo" },
                tip = { raw = "[!TIP]", rendered = "󰌶 Tip", highlight = "RenderMarkdownSuccess" },
                important = { raw = "[!IMPORTANT]", rendered = "󰅾 Important", highlight = "RenderMarkdownHint" },
                warning = { raw = "[!WARNING]", rendered = "󰀪 Warning", highlight = "RenderMarkdownWarn" },
                caution = { raw = "[!CAUTION]", rendered = "󰳦 Caution", highlight = "RenderMarkdownError" },
              },
              link = {
                enabled = true,
                image = "󰥶 ",
                email = "󰀓 ",
                hyperlink = "󰌹 ",
                highlight = "RenderMarkdownLink",
              },
            },
            config = function(_, opts)
              require("render-markdown").setup(opts)
              
              -- Set up custom highlight groups for Kanagawa theme
              local function setup_markdown_highlights()
                local colors = {
                  h1 = "#957fb8", -- Spring violet
                  h2 = "#7e9cd8", -- Crystal blue  
                  h3 = "#7fb4ca", -- Light blue
                  h4 = "#a3d4d5", -- Wave aqua
                  h5 = "#98bb6c", -- Spring green
                  h6 = "#e6c384", -- Autumn yellow
                  code_bg = "#223249",
                  table_head = "#2d4f67",
                  table_row = "#1f1f28",
                  quote = "#7aa89f",
                }
                
                vim.api.nvim_set_hl(0, "RenderMarkdownH1", { fg = colors.h1, bold = true })
                vim.api.nvim_set_hl(0, "RenderMarkdownH2", { fg = colors.h2, bold = true })
                vim.api.nvim_set_hl(0, "RenderMarkdownH3", { fg = colors.h3, bold = true })
                vim.api.nvim_set_hl(0, "RenderMarkdownH4", { fg = colors.h4, bold = true })
                vim.api.nvim_set_hl(0, "RenderMarkdownH5", { fg = colors.h5, bold = true })
                vim.api.nvim_set_hl(0, "RenderMarkdownH6", { fg = colors.h6, bold = true })
                
                vim.api.nvim_set_hl(0, "RenderMarkdownCode", { bg = colors.code_bg })
                vim.api.nvim_set_hl(0, "RenderMarkdownTableHead", { bg = colors.table_head, bold = true })
                vim.api.nvim_set_hl(0, "RenderMarkdownTableRow", { bg = colors.table_row })
                vim.api.nvim_set_hl(0, "RenderMarkdownQuote", { fg = colors.quote, italic = true })
              end
              
              vim.api.nvim_create_autocmd("ColorScheme", {
                pattern = "kanagawa",
                callback = setup_markdown_highlights,
              })
              
              setup_markdown_highlights()
            end,
          },
          
          -- bullets.vim disabled on 2026-05-01: overlapped with
          -- autolist.nvim on <CR>/o in markdown buffers. autolist
          -- (lua native) is the single source of truth now.
          { "bullets-vim/bullets.vim", enabled = false },
          
          {
            "hedyhli/outline.nvim",
            cmd = { "Outline", "OutlineOpen" },
            keys = {
              { "<leader>o", "<cmd>Outline<CR>", desc = "Toggle Outline" },
            },
            -- Only overrides of upstream defaults are listed here;
            -- full default schema lives in the plugin's docs.
            opts = {
              outline_window = {
                position = "right",
                width = 25,
                show_cursorline = true,
              },
              symbol_folding = {
                autofold_depth = 1,
                auto_unfold_hover = true,
                auto_unfold_goto = true,
              },
              preview_window = {
                enabled = true,
                border = "single",
              },
              providers = {
                priority = { "lsp", "coc", "markdown", "norg" },
              },
            },
          },
          
          {
            "gaoDean/autolist.nvim",
            ft = { "markdown", "text" },
            config = function()
              require("autolist").setup({
                enabled = true,
                colon = true,
                tab = {
                  enable = true,
                  indent = true,
                },
              })
              
              -- Set up autolist keybindings for markdown files
              vim.api.nvim_create_autocmd("FileType", {
                pattern = "markdown",
                callback = function()
                  local opts = { buffer = true, silent = true }
                  vim.keymap.set("i", "<tab>", "<cmd>AutolistTab<cr>", opts)
                  vim.keymap.set("i", "<s-tab>", "<cmd>AutolistShiftTab<cr>", opts)
                  vim.keymap.set("i", "<CR>", "<CR><cmd>AutolistNewBullet<cr>", opts)
                  vim.keymap.set("n", "o", "o<cmd>AutolistNewBullet<cr>", opts)
                  vim.keymap.set("n", "O", "O<cmd>AutolistNewBulletBefore<cr>", opts)
                  vim.keymap.set("n", "<CR>", "<cmd>AutolistToggleCheckbox<cr>", opts)
                  vim.keymap.set("n", "<C-r>", "<cmd>AutolistRecalculate<cr>", opts)
                end,
              })
            end,
          },
          
          -- Enhanced formatting with conform.nvim
          {
            "stevearc/conform.nvim",
            event = { "BufWritePre" },
            cmd = { "ConformInfo" },
            keys = {
              {
                "<leader>cf",
                function()
                  require("conform").format({ async = true, lsp_fallback = true })
                end,
                mode = "",
                desc = "Format buffer",
              },
            },
            opts = {
              formatters_by_ft = {
                javascript = { "prettier" },
                javascriptreact = { "prettier" },
                typescript = { "prettier" },
                typescriptreact = { "prettier" },
                vue = { "prettier" },
                css = { "prettier" },
                scss = { "prettier" },
                less = { "prettier" },
                html = { "prettier" },
                json = { "prettier" },
                jsonc = { "prettier" },
                yaml = { "prettier" },
                markdown = { "prettier" },
                graphql = { "prettier" },
                lua = { "stylua" },
                python = { "isort", "black" },
                go = { "goimports", "gofmt" },
                rust = { "rustfmt" },
                nix = { "nixfmt" },
                bash = { "shfmt" },
              },
              format_on_save = {
                timeout_ms = 500,
                lsp_fallback = true,
              },
            },
            init = function()
              vim.o.formatexpr = "v:lua.require'conform'.formatexpr()"
            end,
          },
          
          -- Enhanced linting with nvim-lint
          {
            "mfussenegger/nvim-lint",
            event = { "BufReadPre", "BufNewFile" },
            config = function()
              local lint = require("lint")
              
              lint.linters_by_ft = {
                javascript = { "eslint_d" },
                javascriptreact = { "eslint_d" },
                typescript = { "eslint_d" },
                typescriptreact = { "eslint_d" },
                python = { "pylint" },
                go = { "golangcilint" },
                rust = { "clippy" },
                bash = { "shellcheck" },
                dockerfile = { "hadolint" },
              }
              
              -- Create autocmd which carries out the actual linting
              local lint_augroup = vim.api.nvim_create_augroup("lint", { clear = true })
              
              vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
                group = lint_augroup,
                callback = function()
                  lint.try_lint()
                end,
              })
              
              vim.keymap.set("n", "<leader>cl", function()
                lint.try_lint()
              end, { desc = "Trigger linting for current file" })
            end,
          },
          
          -- TypeScript/JavaScript specific enhancements
          {
            "pmizio/typescript-tools.nvim",
            ft = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
            dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
            opts = {
              on_attach = function(client, bufnr)
                -- Disable ts_ls if typescript-tools is running
                if client.name == "typescript-tools" then
                  local clients = vim.lsp.get_clients({ name = "ts_ls" })
                  for _, c in ipairs(clients) do
                    vim.lsp.stop_client(c.id)
                  end
                end
              end,
              settings = {
                tsserver_file_preferences = {
                  includeInlayParameterNameHints = "all",
                  includeInlayParameterNameHintsWhenArgumentMatchesName = false,
                  includeInlayFunctionParameterTypeHints = true,
                  includeInlayVariableTypeHints = true,
                  includeInlayPropertyDeclarationTypeHints = true,
                  includeInlayFunctionLikeReturnTypeHints = true,
                  includeInlayEnumMemberValueHints = true,
                },
                tsserver_format_options = {
                  allowIncompleteCompletions = false,
                  allowRenameOfImportPath = false,
                },
              },
            },
          },
          
          -- Package.json support
          {
            "vuki656/package-info.nvim",
            ft = "json",
            dependencies = { "MunifTanjim/nui.nvim" },
            opts = {
              colors = {
                up_to_date = "#3C4048",
                outdated = "#d19a66",
              },
              icons = {
                enable = true,
                style = {
                  up_to_date = "|  ",
                  outdated = "|  ",
                },
              },
              autostart = true,
              hide_up_to_date = false,
              hide_unstable_versions = false,
            },
            keys = {
              { "<leader>ns", "<cmd>lua require('package-info').show()<cr>", desc = "Show package info" },
              { "<leader>nc", "<cmd>lua require('package-info').hide()<cr>", desc = "Hide package info" },
              { "<leader>nt", "<cmd>lua require('package-info').toggle()<cr>", desc = "Toggle package info" },
              { "<leader>nu", "<cmd>lua require('package-info').update()<cr>", desc = "Update package" },
              { "<leader>nd", "<cmd>lua require('package-info').delete()<cr>", desc = "Delete package" },
              { "<leader>ni", "<cmd>lua require('package-info').install()<cr>", desc = "Install package" },
              { "<leader>np", "<cmd>lua require('package-info').change_version()<cr>", desc = "Change package version" },
            },
          },

          -- Claude Code IDE integration via MCP. Reuses the OAuth login
          -- that the `claude` CLI already has — no API key needed. Same
          -- WebSocket MCP protocol the official VSCode/JetBrains plugins
          -- use, so you get inline diff approvals + selection-send.
          {
            "coder/claudecode.nvim",
            dependencies = { "folke/snacks.nvim" },
            event = "VeryLazy",
            opts = {},
            keys = {
              { "<C-,>",      "<cmd>ClaudeCode<cr>",        desc = "Toggle Claude Code" },
              { "<leader>cF", "<cmd>ClaudeCodeFocus<cr>",   desc = "Focus Claude" },
              { "<leader>cs", "<cmd>ClaudeCodeSend<cr>",    desc = "Send selection to Claude", mode = { "n", "v" } },
              { "<leader>ca", "<cmd>ClaudeCodeAdd<cr>",     desc = "Add file to Claude context" },
              { "<leader>cm", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
            },
          },

        },
        defaults = {
          lazy = false, -- Should plugins be lazy-loaded by default?
          version = false, -- Always use the latest git commit
        },
        install = { colorscheme = { "kanagawa" } },
        checker = { enabled = false }, -- Don't check for plugin updates automatically
        performance = {
          rtp = {
            -- Disable some rtp plugins
            disabled_plugins = {
              "gzip",
              "matchit", 
              "matchparen",
              "netrwPlugin",
              "tarPlugin",
              "tohtml",
              "tutor",
              "zipPlugin",
            },
          },
        },
      })
      
      -- Better clipboard support for Wayland
      vim.g.clipboard = {
        name = "wl-clipboard",
        copy = {
          ["+"] = "wl-copy --trim-newline",
          ["*"] = "wl-copy --trim-newline",
        },
        paste = {
          ["+"] = "wl-paste --no-newline", 
          ["*"] = "wl-paste --no-newline",
        },
      }
      
      -- Custom diagnostic configuration (improve on LazyVim defaults)
      vim.diagnostic.config({
        underline = true,
        update_in_insert = false,
        virtual_text = {
          spacing = 4,
          source = "if_many",
          prefix = "●",
        },
        severity_sort = true,
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = "✘",
            [vim.diagnostic.severity.WARN] = "▲", 
            [vim.diagnostic.severity.HINT] = "⚑",
            [vim.diagnostic.severity.INFO] = "»",
          },
        },
      })
      
      -- Auto-command for loading time tracking
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        callback = function()
          local stats = require("lazy").stats()
          
          -- Calculate total startup time from our tracking
          local total_time = 0
          if vim.g.start_time then
            local end_time = vim.uv.hrtime()
            total_time = (end_time - vim.g.start_time) / 1e6 -- Convert nanoseconds to milliseconds
          end
          
          -- Use lazy.nvim's startup time (converted to ms) or our tracking, whichever is higher
          local lazy_ms = stats.startuptime * 1000
          local display_ms = math.max(lazy_ms, total_time)
          
          -- Round to 1 decimal place
          local rounded_ms = math.floor(display_ms * 10 + 0.5) / 10
          
          vim.notify(
            "⚡ Neovim loaded " .. stats.loaded .. "/" .. stats.count .. " plugins in " .. rounded_ms .. "ms",
            vim.log.levels.INFO,
            { title = "Lazy.nvim" }
          )
        end,
      })
      
      -- Window-focus + float + winsep highlights, set on every
      -- colorscheme load so kanagawa or DMS's matugen-driven palette
      -- both pick them up. The previous WinEnter/WinLeave winblend=10
      -- dimming was removed (uncommon, distracting on inactive windows);
      -- the active/inactive distinction comes from NormalNC instead.
      local function setup_window_highlights()
        local violet = "#957FB8" -- Kanagawa spring violet
        local crystal_blue = "#7E9CD8"
        local wave_bg = "#1F1F28"
        local sumi_bg = "#16161D"

        vim.api.nvim_set_hl(0, "NormalFloat", { bg = wave_bg })
        vim.api.nvim_set_hl(0, "FloatBorder", { fg = crystal_blue, bg = wave_bg })
        -- Subtle bg shift for inactive windows; pairs with native NormalNC.
        vim.api.nvim_set_hl(0, "NormalNC", { bg = sumi_bg })
        -- Window-split separator (replaces colorful-winsep.nvim).
        vim.api.nvim_set_hl(0, "WinSeparator", { fg = violet })
      end

      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("WindowHighlights", { clear = true }),
        pattern = "*",
        callback = setup_window_highlights,
      })
      setup_window_highlights()
      
      -- Essential keybindings.
      -- <leader>ff/fg/fb/fh/e are owned by the snacks.nvim plugin
      -- spec's `keys = {}` table (lazy-loads snacks on first press),
      -- so they're not redefined here.
      vim.keymap.set("n", "<leader>l", "<cmd>Lazy<cr>", { desc = "Lazy Plugin Manager" })
      
      -- Markdown-specific settings and keybindings
      vim.api.nvim_create_augroup("MarkdownSettings", { clear = true })
      
      vim.api.nvim_create_autocmd("FileType", {
        group = "MarkdownSettings",
        pattern = "markdown",
        callback = function()
          -- Enable text wrapping for markdown
          vim.opt_local.wrap = true
          vim.opt_local.linebreak = true
          vim.opt_local.breakindent = true
          vim.opt_local.showbreak = "↪ "
          vim.opt_local.conceallevel = 2
          vim.opt_local.concealcursor = "nc"
          
          -- Set up spell checking
          vim.opt_local.spell = true
          vim.opt_local.spelllang = "en_us"
          
          -- Better text width for markdown (disabled auto-breaking)
          vim.opt_local.textwidth = 0  -- Disable automatic line breaking
          vim.opt_local.colorcolumn = "80"
          
          -- Markdown-specific keybindings
          local opts = { buffer = true, silent = true }
          
          -- Text formatting
          vim.keymap.set("n", "<leader>mb", "viwS*", vim.tbl_extend("force", opts, { desc = "Bold word" }))
          vim.keymap.set("v", "<leader>mb", "S*", vim.tbl_extend("force", opts, { desc = "Bold selection" }))
          vim.keymap.set("n", "<leader>mi", "viwS_", vim.tbl_extend("force", opts, { desc = "Italic word" }))
          vim.keymap.set("v", "<leader>mi", "S_", vim.tbl_extend("force", opts, { desc = "Italic selection" }))
          vim.keymap.set("n", "<leader>mc", "viw<cmd>lua vim.fn.setreg('\"', '`' .. vim.fn.getreg('\"') .. '`')<cr>p", vim.tbl_extend("force", opts, { desc = "Code word" }))
          vim.keymap.set("v", "<leader>mc", "c`<C-r>\"`<Esc>", vim.tbl_extend("force", opts, { desc = "Code selection" }))
          
          -- Headers
          vim.keymap.set("n", "<leader>m1", "I# <Esc>", vim.tbl_extend("force", opts, { desc = "H1 Header" }))
          vim.keymap.set("n", "<leader>m2", "I## <Esc>", vim.tbl_extend("force", opts, { desc = "H2 Header" }))
          vim.keymap.set("n", "<leader>m3", "I### <Esc>", vim.tbl_extend("force", opts, { desc = "H3 Header" }))
          vim.keymap.set("n", "<leader>m4", "I#### <Esc>", vim.tbl_extend("force", opts, { desc = "H4 Header" }))
          vim.keymap.set("n", "<leader>m5", "I##### <Esc>", vim.tbl_extend("force", opts, { desc = "H5 Header" }))
          vim.keymap.set("n", "<leader>m6", "I###### <Esc>", vim.tbl_extend("force", opts, { desc = "H6 Header" }))
          
          -- Lists and checkboxes
          vim.keymap.set("n", "<leader>ml", "I- <Esc>A", vim.tbl_extend("force", opts, { desc = "List item" }))
          vim.keymap.set("n", "<leader>mx", "I- [ ] <Esc>A", vim.tbl_extend("force", opts, { desc = "Checkbox" }))
          
          -- Links and images  
          vim.keymap.set("v", "<leader>mL", "c[<C-r>\"]()<Esc>i", vim.tbl_extend("force", opts, { desc = "Link from selection" }))
          vim.keymap.set("v", "<leader>mI", "c![<C-r>\"]()<Esc>i", vim.tbl_extend("force", opts, { desc = "Image from selection" }))
          
          -- Tables
          vim.keymap.set("n", "<leader>mt", "o| Column 1 | Column 2 | Column 3 |<CR>|----------|----------|----------|<CR>| Cell 1   | Cell 2   | Cell 3   |<Esc>", vim.tbl_extend("force", opts, { desc = "Insert table" }))
          
          -- Code blocks
          vim.keymap.set("n", "<leader>mC", "o```<CR>```<Esc>ka", vim.tbl_extend("force", opts, { desc = "Code block" }))
          
          -- Quotes
          vim.keymap.set("n", "<leader>mq", "I> <Esc>", vim.tbl_extend("force", opts, { desc = "Quote line" }))
          vim.keymap.set("v", "<leader>mq", ":s/^/> /<CR>", vim.tbl_extend("force", opts, { desc = "Quote selection" }))
          
          -- Horizontal rule
          vim.keymap.set("n", "<leader>mr", "o---<Esc>", vim.tbl_extend("force", opts, { desc = "Horizontal rule" }))
          
          -- Navigation
          vim.keymap.set("n", "]]", "/^#\\+\\s<CR>", vim.tbl_extend("force", opts, { desc = "Next header" }))
          vim.keymap.set("n", "[[", "?^#\\+\\s<CR>", vim.tbl_extend("force", opts, { desc = "Previous header" }))
        end,
      })
      
    '';
  };
}
{ config, pkgs, ... }:

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
      if not vim.loop.fs_stat(lazypath) then
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
      vim.g.start_time = vim.loop.hrtime()
      
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

      -- Auto-reload files when changed externally (silent)
      vim.opt.autoread = true
      vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
        pattern = "*",
        callback = function()
          if vim.fn.getcmdwintype() == "" then
            vim.cmd("checktime")
          end
        end,
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
              vim.cmd("colorscheme kanagawa")
            end,
          },
          
          -- Override LazyVim dashboard with alpha configuration
          {
            "goolord/alpha-nvim",
            event = "VimEnter",
            opts = function()
              local dashboard = require("alpha.themes.dashboard")
              
              -- Custom ASCII art header (Kanagawa-inspired wave)
              dashboard.section.header.val = {
                "                                                     ",
                "  ███╗   ██╗███████╗ ██████╗ ██╗   ██╗██╗███╗   ███╗ ",
                "  ████╗  ██║██╔════╝██╔═══██╗██║   ██║██║████╗ ████║ ",
                "  ██╔██╗ ██║█████╗  ██║   ██║██║   ██║██║██╔████╔██║ ",
                "  ██║╚██╗██║██╔══╝  ██║   ██║╚██╗ ██╔╝██║██║╚██╔╝██║ ",
                "  ██║ ╚████║███████╗╚██████╔╝ ╚████╔╝ ██║██║ ╚═╝ ██║ ",
                "  ╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚═╝     ╚═╝ ",
                "                                                     ",
                "           🌊 Kanagawa Theme - Like the Great Wave    ",
                "                                                     ",
              }
              
              -- Custom buttons  
              dashboard.section.buttons.val = {
                dashboard.button("f", "  Find File", ":Telescope find_files <CR>"),
                dashboard.button("e", "  New File", ":ene <BAR> startinsert <CR>"),
                dashboard.button("r", "  Recent Files", ":Telescope oldfiles <CR>"),
                dashboard.button("g", "  Find Text", ":Telescope live_grep <CR>"),
                dashboard.button("c", "  Configuration", ":e ~/.config/nvim/init.lua <CR>"),
                dashboard.button("s", "  Load Session", ":SessionLoad <CR>"),
                dashboard.button("l", "  Lazy", ":Lazy <CR>"),
                dashboard.button("q", "  Quit", ":qa <CR>"),
              }
              
              -- Footer with load time
              dashboard.section.footer.val = function()
                local stats = require("lazy").stats()
                local ms = (math.floor(stats.startuptime * 100 + 0.5) / 100)
                return {
                  "",
                  "⚡ Neovim loaded " .. stats.loaded .. "/" .. stats.count .. " plugins in " .. ms .. "ms",
                  "",
                  "The Great Wave off Kanagawa inspires this colorful journey",
                  "~ Katsushika Hokusai ~",
                }
              end
              
              return dashboard
            end,
            config = function(_, dashboard)
              -- Set custom highlight groups
              vim.api.nvim_create_autocmd("User", {
                once = true,
                pattern = "LazyVimStarted",
                callback = function()
                  -- Header: Use Kanagawa spring violet
                  vim.api.nvim_set_hl(0, "AlphaHeader", { fg = "#957fb8" })
                  -- Buttons: Use Kanagawa crystal blue
                  vim.api.nvim_set_hl(0, "AlphaButtons", { fg = "#7e9cd8" })
                  -- Footer: Use Kanagawa fuji gray
                  vim.api.nvim_set_hl(0, "AlphaFooter", { fg = "#727169", italic = true })
                  
                  dashboard.section.header.opts.hl = "AlphaHeader"
                  dashboard.section.buttons.opts.hl = "AlphaButtons"
                  dashboard.section.footer.opts.hl = "AlphaFooter"
                end,
              })
              
              require("alpha").setup(dashboard.opts)
              
              -- Disable folding on alpha buffer
              vim.api.nvim_create_autocmd("FileType", {
                pattern = "alpha",
                callback = function()
                  vim.opt_local.foldenable = false
                end,
              })
            end,
          },
          
          -- Override telescope configuration
          {
            "nvim-telescope/telescope.nvim",
            opts = {
              defaults = {
                layout_strategy = "horizontal",
                layout_config = { prompt_position = "top" },
                sorting_strategy = "ascending",
                winblend = 0,
                mappings = {
                  i = {
                    ["<C-h>"] = "which_key"
                  }
                }
              },
              extensions = {
                fzf = {
                  fuzzy = true,
                  override_generic_sorter = true,
                  override_file_sorter = true,
                  case_mode = "smart_case",
                }
              }
            },
          },
          
          -- Completion setup
          {
            "hrsh7th/nvim-cmp",
            event = "InsertEnter",
            dependencies = {
              -- LSP source
              "hrsh7th/cmp-nvim-lsp",
              
              -- Buffer completions
              "hrsh7th/cmp-buffer",
              
              -- Path completions
              "hrsh7th/cmp-path",
              
              -- Command line completions
              "hrsh7th/cmp-cmdline",
              
              -- Snippet engine and completion
              {
                "L3MON4D3/LuaSnip",
                build = function()
                  -- Build jsregexp for better snippet transformations
                  if vim.fn.executable("make") == 1 then
                    return "make install_jsregexp"
                  end
                  return nil
                end,
                dependencies = { "rafamadriz/friendly-snippets" },
              },
              "saadparwaiz1/cmp_luasnip",
              
              -- Additional sources
              "hrsh7th/cmp-nvim-lua", -- Neovim Lua API
              "hrsh7th/cmp-nvim-lsp-signature-help", -- LSP signature help
              "hrsh7th/cmp-calc", -- Calculator
              "f3fora/cmp-spell", -- Spell suggestions
              "hrsh7th/cmp-emoji", -- Emoji completions
            },
            config = function()
              local cmp = require("cmp")
              local luasnip = require("luasnip")
              
              -- Load friendly snippets
              require("luasnip.loaders.from_vscode").lazy_load()
              
              -- Better snippet navigation
              local has_words_before = function()
                unpack = unpack or table.unpack
                local line, col = unpack(vim.api.nvim_win_get_cursor(0))
                return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
              end
              
              cmp.setup({
                enabled = function()
                  -- Disable completion in comments
                  local context = require("cmp.config.context")
                  if vim.api.nvim_get_mode().mode == 'c' then
                    return true
                  else
                    return not context.in_treesitter_capture("comment") and not context.in_syntax_group("Comment")
                  end
                end,
                
                snippet = {
                  expand = function(args)
                    luasnip.lsp_expand(args.body)
                  end,
                },
                
                completion = {
                  completeopt = "menu,menuone,noinsert",
                },
                
                formatting = {
                  fields = { "kind", "abbr", "menu" },
                  format = function(entry, vim_item)
                    local kind_icons = {
                      Text = "󰉿",
                      Method = "󰆧",
                      Function = "󰊕",
                      Constructor = "",
                      Field = "󰜢",
                      Variable = "󰀫",
                      Class = "󰠱",
                      Interface = "",
                      Module = "",
                      Property = "󰜢",
                      Unit = "󰑭",
                      Value = "󰎠",
                      Enum = "",
                      Keyword = "󰌋",
                      Snippet = "",
                      Color = "󰏘",
                      File = "󰈙",
                      Reference = "󰈇",
                      Folder = "󰉋",
                      EnumMember = "",
                      Constant = "󰏿",
                      Struct = "󰙅",
                      Event = "",
                      Operator = "󰆕",
                      TypeParameter = "",
                    }
                    
                    vim_item.kind = string.format('%s %s', kind_icons[vim_item.kind], vim_item.kind)
                    vim_item.menu = ({
                      nvim_lsp = "[LSP]",
                      nvim_lua = "[Lua]",
                      luasnip = "[LuaSnip]",
                      buffer = "[Buffer]",
                      path = "[Path]",
                      calc = "[Calc]",
                      spell = "[Spell]",
                      dictionary = "[Dict]",
                      emoji = "[Emoji]",
                    })[entry.source.name]
                    return vim_item
                  end,
                },
                
                window = {
                  completion = cmp.config.window.bordered({
                    border = "rounded",
                    winhighlight = "Normal:CmpPmenu,CursorLine:PmenuSel,Search:None",
                  }),
                  documentation = cmp.config.window.bordered({
                    border = "rounded",
                    winhighlight = "Normal:CmpDoc",
                  }),
                },
                
                mapping = cmp.mapping.preset.insert({
                  ["<C-b>"] = cmp.mapping.scroll_docs(-4),
                  ["<C-f>"] = cmp.mapping.scroll_docs(4),
                  ["<C-Space>"] = cmp.mapping.complete(),
                  ["<C-e>"] = cmp.mapping.abort(),
                  ["<CR>"] = cmp.mapping.confirm({ 
                    behavior = cmp.ConfirmBehavior.Replace,
                    select = true,
                  }),
                  
                  -- Super Tab like behavior
                  ["<Tab>"] = cmp.mapping(function(fallback)
                    if cmp.visible() then
                      cmp.select_next_item()
                    elseif luasnip.expand_or_jumpable() then
                      luasnip.expand_or_jump()
                    elseif has_words_before() then
                      cmp.complete()
                    else
                      fallback()
                    end
                  end, { "i", "s" }),
                  
                  ["<S-Tab>"] = cmp.mapping(function(fallback)
                    if cmp.visible() then
                      cmp.select_prev_item()
                    elseif luasnip.jumpable(-1) then
                      luasnip.jump(-1)
                    else
                      fallback()
                    end
                  end, { "i", "s" }),
                }),
                
                sources = cmp.config.sources({
                  { name = "nvim_lsp", priority = 1000 },
                  { name = "nvim_lsp_signature_help", priority = 1000 },
                  { name = "luasnip", priority = 750 },
                  { name = "nvim_lua", priority = 500 },
                  { name = "path", priority = 250 },
                }, {
                  { name = "buffer", priority = 500, keyword_length = 3 },
                  { name = "calc", priority = 150 },
                  { name = "spell", priority = 100 },
                  { name = "dictionary", priority = 100, keyword_length = 2 },
                  { name = "emoji", priority = 100 },
                }),
                
                experimental = {
                  ghost_text = {
                    hl_group = "CmpGhostText",
                  },
                },
              })
              
              -- Command line completion (disabled for cleaner Telescope experience)
              -- Uncomment these if you want cmdline completion in Vim's command mode
              -- cmp.setup.cmdline({ '/', '?' }, {
              --   mapping = cmp.mapping.preset.cmdline(),
              --   sources = {
              --     { name = 'buffer' }
              --   }
              -- })
              -- 
              -- cmp.setup.cmdline(':', {
              --   mapping = cmp.mapping.preset.cmdline(),
              --   sources = cmp.config.sources({
              --     { name = 'path' }
              --   }, {
              --     { name = 'cmdline' }
              --   })
              -- })
              
              -- Set up custom highlight groups
              local function setup_cmp_highlights()
                vim.api.nvim_set_hl(0, "CmpGhostText", { link = "Comment", default = true })
                vim.api.nvim_set_hl(0, "CmpPmenu", { bg = "#1f1f28", fg = "#dcd7ba" })
                vim.api.nvim_set_hl(0, "CmpDoc", { bg = "#1f1f28", fg = "#dcd7ba" })
              end
              
              vim.api.nvim_create_autocmd("ColorScheme", {
                pattern = "kanagawa",
                callback = setup_cmp_highlights,
              })
              
              setup_cmp_highlights()
            end,
          },
          
          -- Dictionary completion plugin
          {
            "uga-rosa/cmp-dictionary",
            ft = { "markdown", "text", "tex", "latex" },
            config = function()
              require("cmp_dictionary").setup({
                paths = {
                  "/run/current-system/sw/share/hunspell/en_US.dic",
                  "/run/current-system/sw/share/hunspell/en_GB.dic"
                },
                exact_length = 2,
                first_case_insensitive = true,
                document = {
                  enable = false,
                },
              })
            end,
          },

          -- LSP Configuration
          {
            "neovim/nvim-lspconfig",
            event = { "BufReadPre", "BufNewFile" },
            dependencies = {
              "hrsh7th/nvim-cmp",
            },
            config = function()
              local capabilities = require("cmp_nvim_lsp").default_capabilities()
              
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

              -- Enable LSP servers for appropriate filetypes
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "nix" },
                callback = function()
                  vim.lsp.enable('nil_ls')
                end,
              })
              
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "sh", "bash" },
                callback = function()
                  vim.lsp.enable('bashls')
                end,
              })
              
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "markdown" },
                callback = function()
                  vim.lsp.enable('marksman')
                end,
              })
              
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "python" },
                callback = function()
                  vim.lsp.enable('pyright')
                end,
              })
              
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "go" },
                callback = function()
                  vim.lsp.enable('gopls')
                end,
              })
              
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
                callback = function()
                  vim.lsp.enable('ts_ls')
                end,
              })
              
              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "java" },
                callback = function()
                  vim.lsp.enable('jdtls')
                end,
              })

              vim.api.nvim_create_autocmd("FileType", {
                pattern = { "rust" },
                callback = function()
                  vim.lsp.enable('rust_analyzer')
                end,
              })

              -- LSP keybindings
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
                  vim.keymap.set("n", "<leader>cf", function()
                    vim.lsp.buf.format({ async = true })
                  end, opts)
                end,
              })
              
              -- Auto-format on save
              vim.api.nvim_create_autocmd("BufWritePre", {
                group = vim.api.nvim_create_augroup("AutoFormat", {}),
                callback = function()
                  vim.lsp.buf.format({ async = false })
                end,
              })
            end,
          },
          
          -- File explorer (lazy-loaded on first use)
          {
            "nvim-tree/nvim-tree.lua",
            cmd = { "NvimTreeToggle", "NvimTreeFocus", "NvimTreeFindFile", "NvimTreeCollapse" },
            keys = {
              { "<leader>e", "<cmd>NvimTreeToggle<cr>", desc = "Toggle file explorer" },
            },
            opts = {
              git = {
                enable = true,
                ignore = false,
              },
              view = {
                width = 30,
                side = "left",
              },
            },
          },
          
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
                  theme = "kanagawa", -- Keep kanagawa theme instead of auto
                  globalstatus = true,
                  component_separators = { left = "", right = "" },
                  section_separators = { left = "", right = "" },
                  disabled_filetypes = {
                    statusline = { "dashboard", "alpha", "starter" },
                    winbar = { "help", "alpha", "dashboard", "NvimTree", "Trouble", "starter" },
                  },
                  disabled_buftypes = {
                    "quickfix",
                    "prompt",
                  },
                  ignore_focus = {
                    "NvimTree",
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
                extensions = { "nvim-tree", "lazy", "quickfix" },
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
                auto_install = true,
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
          
          -- Auto pairs (lazy-loaded when entering insert mode)
          {
            "windwp/nvim-autopairs",
            event = "InsertEnter", 
            opts = {},
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
          
          -- Window focus highlighting
          {
            "nvim-zh/colorful-winsep.nvim",
            event = "WinNew", 
            config = function()
              require("colorful-winsep").setup({
                highlight = "#957FB8", -- Kanagawa spring violet for window separators
                interval = 30,
                no_exec_files = { "packer", "TelescopePrompt", "mason", "CompetiTest", "NvimTree" },
                symbols = { "─", "│", "┌", "┐", "└", "┘" },
              })
            end,
          },
          
          -- Advanced Markdown Editing Plugins
          {
            "iamcco/markdown-preview.nvim",
            ft = { "markdown" },
            cmd = { "MarkdownPreview", "MarkdownPreviewStop", "MarkdownPreviewToggle" },
            build = function()
              vim.fn["mkdp#util#install"]()
            end,
            keys = {
              { "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", desc = "Toggle Markdown Preview", ft = "markdown" },
            },
            config = function()
              vim.g.mkdp_filetypes = { "markdown" }
              vim.g.mkdp_auto_start = 0
              vim.g.mkdp_auto_close = 1
              vim.g.mkdp_refresh_slow = 0
              vim.g.mkdp_command_for_global = 0
              vim.g.mkdp_open_to_the_world = 0
              vim.g.mkdp_open_ip = ""
              vim.g.mkdp_browser = ""
              vim.g.mkdp_echo_preview_url = 0
              vim.g.mkdp_browserfunc = ""
              vim.g.mkdp_preview_options = {
                mkit = {},
                katex = {},
                uml = {},
                maid = {},
                disable_sync_scroll = 0,
                sync_scroll_type = "middle",
                hide_yaml_meta = 1,
                sequence_diagrams = {},
                flowchart_diagrams = {},
                content_editable = false,
                disable_filename = 0,
                toc = {},
              }
              vim.g.mkdp_markdown_css = ""
              vim.g.mkdp_highlight_css = ""
              vim.g.mkdp_port = ""
              vim.g.mkdp_page_title = "「''${name}」"
              vim.g.mkdp_theme = "dark"
            end,
          },
          
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
          
          {
            "bullets-vim/bullets.vim",
            ft = { "markdown", "text", "gitcommit" },
            config = function()
              vim.g.bullets_enabled_file_types = {
                "markdown",
                "text", 
                "gitcommit",
                "scratch",
              }
              vim.g.bullets_enable_in_empty_buffers = 0
              vim.g.bullets_set_mappings = 1
              vim.g.bullets_mapping_leader = ""
              vim.g.bullets_delete_last_bullet_if_empty = 1
              vim.g.bullets_line_spacing = 1
              vim.g.bullets_pad_right = 1
              vim.g.bullets_max_alpha_characters = 2
              vim.g.bullets_renumber_on_change = 1
              vim.g.bullets_nested_checkboxes = 1
              vim.g.bullets_checkbox_markers = " .oOX"
              vim.g.bullets_outline_levels = { "ROM", "ABC", "num", "abc", "rom", "ABC", "num" }
            end,
          },
          
          {
            "hedyhli/outline.nvim",
            cmd = { "Outline", "OutlineOpen" },
            keys = {
              { "<leader>o", "<cmd>Outline<CR>", desc = "Toggle Outline" },
            },
            opts = {
              outline_window = {
                position = "right",
                width = 25,
                relative_width = true,
                auto_close = false,
                auto_jump = false,
                jump_highlight_duration = 300,
                center_on_jump = true,
                show_numbers = false,
                show_relative_numbers = false,
                wrap = false,
                show_cursorline = true,
                hide_cursor = false,
                focus_on_open = false,
                winhl = "",
              },
              outline_items = {
                show_symbol_details = true,
                show_symbol_lineno = false,
                highlight_hovered_item = true,
                auto_set_cursor = true,
              },
              guides = {
                enabled = true,
                markers = {
                  bottom = "└",
                  middle = "├", 
                  vertical = "│",
                },
              },
              symbol_folding = {
                autofold_depth = 1,
                auto_unfold_hover = true,
                auto_unfold_goto = true,
                markers = { "", "" },
              },
              preview_window = {
                enabled = true,
                border = "single",
                min_height = 4,
                min_width = 30,
                show_title = true,
                show_cursorline = true,
                live = false,
              },
              keymaps = {
                show_help = "?",
                close = { "<Esc>", "q" },
                goto_location = "<CR>",
                peek_location = "o",
                goto_and_close = "<S-CR>",
                restore_location = "<C-g>",
                hover_symbol = "<C-space>",
                toggle_preview = "K",
                rename_symbol = "r",
                code_actions = "a",
                fold = "h",
                unfold = "l",
                fold_all = "W",
                unfold_all = "E",
                fold_reset = "R",
                down_and_jump = "<C-j>",
                up_and_jump = "<C-k>",
              },
              providers = {
                priority = { "lsp", "coc", "markdown", "norg" },
                lsp = {
                  blacklist_clients = {},
                },
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
            local end_time = vim.loop.hrtime()
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
      
      -- Window focus highlighting and dimming
      vim.api.nvim_create_augroup("WindowFocus", { clear = true })
      
      -- Set up window focus highlighting colors (Kanagawa theme)
      local function setup_window_highlights()
        -- Colors from Kanagawa theme
        local colors = {
          focused_bg = "#1F1F28",      -- Kanagawa wave bg
          unfocused_bg = "#16161D",    -- Darker Kanagawa bg
          focused_fg = "#DCD7BA",      -- Kanagawa fg
          unfocused_fg = "#727169",    -- Dimmed Kanagawa fg
          focused_border = "#7E9CD8",  -- Kanagawa crystal blue
          unfocused_border = "#54546D", -- Dimmed border
        }
        
        -- Set highlight groups
        vim.api.nvim_set_hl(0, "NormalFloat", { bg = colors.focused_bg })
        vim.api.nvim_set_hl(0, "FloatBorder", { fg = colors.focused_border, bg = colors.focused_bg })
        
        -- Custom highlight groups for window focus
        vim.api.nvim_set_hl(0, "ActiveWindow", { bg = colors.focused_bg })
        vim.api.nvim_set_hl(0, "InactiveWindow", { bg = colors.unfocused_bg })
      end
      
      -- Apply highlights after colorscheme loads
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = "WindowFocus",
        pattern = "*",
        callback = setup_window_highlights,
      })
      
      -- Window focus events
      vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        group = "WindowFocus",
        callback = function()
          -- Highlight focused window
          vim.opt_local.winhighlight = "Normal:ActiveWindow,NormalNC:InactiveWindow"
          vim.opt_local.winblend = 0
        end,
      })
      
      vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
        group = "WindowFocus",
        callback = function()
          -- Dim unfocused window
          vim.opt_local.winhighlight = "Normal:InactiveWindow,NormalNC:InactiveWindow"
          vim.opt_local.winblend = 10
        end,
      })
      
      -- Set initial highlight groups
      setup_window_highlights()
      
      -- Essential keybindings
      vim.keymap.set("n", "<leader>l", "<cmd>Lazy<cr>", { desc = "Lazy Plugin Manager" })
      vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files<cr>", { desc = "Find Files" })
      vim.keymap.set("n", "<leader>fg", "<cmd>Telescope live_grep<cr>", { desc = "Live Grep" })
      vim.keymap.set("n", "<leader>fb", "<cmd>Telescope buffers<cr>", { desc = "Buffers" })
      vim.keymap.set("n", "<leader>fh", "<cmd>Telescope help_tags<cr>", { desc = "Help Tags" })
      vim.keymap.set("n", "<leader>e", "<cmd>NvimTreeToggle<cr>", { desc = "Toggle File Explorer" })
      
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
      
      -- Configure LTeX Language Server for Grammar and Spell Checking
      vim.lsp.config('ltex', {
        settings = {
          ltex = {
            language = "en-US",
            additionalRules = {
              enablePickyRules = true,
              motherTongue = "pt-BR",
            },
            checkFrequency = "save",
            dictionary = {
              ["en-US"] = {},
              ["pt-BR"] = {},
            },
            disabledRules = {
              ["en-US"] = {},
              ["pt-BR"] = {},
            },
          },
        },
      })
      
      -- Enable LTeX for appropriate filetypes
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "markdown", "tex", "latex", "rst", "org", "text", "gitcommit" },
        callback = function()
          vim.lsp.enable('ltex')
        end,
      })
    '';
  };
}
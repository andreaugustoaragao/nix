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
              "hrsh7th/cmp-nvim-lsp",
              "hrsh7th/cmp-buffer", 
              "hrsh7th/cmp-path",
              "hrsh7th/cmp-cmdline",
              "L3MON4D3/LuaSnip",
              "saadparwaiz1/cmp_luasnip",
            },
            config = function()
              local cmp = require("cmp")
              cmp.setup({
                snippet = {
                  expand = function(args)
                    require("luasnip").lsp_expand(args.body)
                  end,
                },
                mapping = cmp.mapping.preset.insert({
                  ["<C-b>"] = cmp.mapping.scroll_docs(-4),
                  ["<C-f>"] = cmp.mapping.scroll_docs(4),
                  ["<C-Space>"] = cmp.mapping.complete(),
                  ["<C-e>"] = cmp.mapping.abort(),
                  ["<CR>"] = cmp.mapping.confirm({ select = true }),
                }),
                sources = cmp.config.sources({
                  { name = "nvim_lsp" },
                  { name = "luasnip" },
                }, {
                  { name = "buffer" },
                })
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
              local lspconfig = require("lspconfig")
              local capabilities = require("cmp_nvim_lsp").default_capabilities()
              
              -- Enable file watching capabilities (important for project-wide changes)
              capabilities.workspace = capabilities.workspace or {}
              capabilities.workspace.didChangeWatchedFiles = {
                dynamicRegistration = true,
                relativePatternSupport = true,
              }
              
              -- Nix LSP
              lspconfig.nil_ls.setup({
                capabilities = capabilities,
              })
              
              -- Bash LSP  
              lspconfig.bashls.setup({
                capabilities = capabilities,
              })
              
              -- Markdown LSP
              lspconfig.marksman.setup({
                capabilities = capabilities,
              })
              
              -- Python LSP
              lspconfig.pyright.setup({
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
              lspconfig.gopls.setup({
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
                      fieldalignment = true,
                      nilness = true,
                      unusedparams = true,
                      unusedwrite = true,
                      useany = true,
                    },
                  },
                },
              })
              
              -- TypeScript LSP
              lspconfig.ts_ls.setup({
                capabilities = capabilities,
              })
              
              -- Java LSP  
              lspconfig.jdtls.setup({
                capabilities = capabilities,
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
                  vim.keymap.set("n", "<leader>f", function()
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
            opts = {
              ensure_installed = {
                "nix", "bash", "markdown", "markdown_inline", "lua", "vim", "vimdoc",
                "python", "go", "javascript", "typescript", "tsx", "json", "yaml", 
                "java", "dockerfile", "terraform"
              },
            },
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
    '';
  };
}
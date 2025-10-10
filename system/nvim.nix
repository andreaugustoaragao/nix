{ config, pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    
    # System-wide Neovim configuration for all users (including root)
    configure = {
      packages.myVimPackage = with pkgs.vimPlugins; {
        start = [
          # Color theme
          kanagawa-nvim
          
          # Telescope and dependencies
          telescope-nvim
          plenary-nvim  # Required dependency for telescope
          telescope-fzf-native-nvim
          
          # LSP Configuration
          nvim-lspconfig
          mason-nvim
          mason-lspconfig-nvim
          
          # Completion
          nvim-cmp
          cmp-nvim-lsp
          cmp-buffer
          cmp-path
          cmp-cmdline
          luasnip
          cmp_luasnip
          
          # Treesitter for syntax highlighting
          (nvim-treesitter.withPlugins (p: [
            p.nix
            p.bash
            p.markdown
            p.markdown_inline
            p.lua
            p.vim
            p.vimdoc
            p.python
            p.go
            p.javascript
            p.typescript
            p.tsx
            p.json
            p.yaml
            p.java
            p.dockerfile
            p.terraform
          ]))
          
          # File explorer
          nvim-tree-lua
          nvim-web-devicons
          
          # Status line
          lualine-nvim
          
          # Git integration
          gitsigns-nvim
          
          # Auto pairs
          nvim-autopairs
          
          # Which-key for keybinding help
          which-key-nvim
          
          # Alpha dashboard
          alpha-nvim
        ];
      };
      
      customRC = ''
        lua << EOF
        -- Kanagawa colorscheme
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
        
        -- Basic settings
        vim.opt.number = true
        vim.opt.relativenumber = true
        vim.opt.expandtab = true
        vim.opt.shiftwidth = 2
        vim.opt.tabstop = 2
        vim.opt.smartindent = true
        vim.opt.wrap = false
        vim.opt.ignorecase = true
        vim.opt.smartcase = true
        vim.opt.hlsearch = false
        vim.opt.incsearch = true
        vim.opt.termguicolors = true
        vim.opt.scrolloff = 8
        vim.opt.signcolumn = "yes"
        vim.opt.updatetime = 50
        
        -- Leader key
        vim.g.mapleader = " "
        
        -- Telescope configuration
        require('telescope').setup{
          defaults = {
            mappings = {
              i = {
                ["<C-h>"] = "which_key"
              }
            }
          },
          pickers = {},
          extensions = {
            fzf = {
              fuzzy = true,
              override_generic_sorter = true,
              override_file_sorter = true,
              case_mode = "smart_case",
            }
          }
        }
        require('telescope').load_extension('fzf')
        
        -- Telescope keybindings
        local builtin = require('telescope.builtin')
        vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
        vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
        vim.keymap.set('n', '<leader>fb', builtin.buffers, {})
        vim.keymap.set('n', '<leader>fh', builtin.help_tags, {})
        
        -- Setup Mason (but don't auto-install on NixOS)
        require('mason').setup({
          PATH = "skip",  -- Skip PATH modification on NixOS
        })
        require('mason-lspconfig').setup({
          -- Don't auto-install on NixOS, we use Nix packages instead
        })
        
        -- Completion setup
        local cmp = require('cmp')
        cmp.setup({
          snippet = {
            expand = function(args)
              require('luasnip').lsp_expand(args.body)
            end,
          },
          mapping = cmp.mapping.preset.insert({
            ['<C-b>'] = cmp.mapping.scroll_docs(-4),
            ['<C-f>'] = cmp.mapping.scroll_docs(4),
            ['<C-Space>'] = cmp.mapping.complete(),
            ['<C-e>'] = cmp.mapping.abort(),
            ['<CR>'] = cmp.mapping.confirm({ select = true }),
          }),
          sources = cmp.config.sources({
            { name = 'nvim_lsp' },
            { name = 'luasnip' },
          }, {
            { name = 'buffer' },
          })
        })
        
        -- LSP capabilities
        local capabilities = require('cmp_nvim_lsp').default_capabilities()
        
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
        
        -- Python LSP (Pyright)
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
        vim.lsp.config('ts_ls', {
          capabilities = capabilities,
        })
        
        -- Java LSP
        vim.lsp.config('jdtls', {
          capabilities = capabilities,
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
        
        -- LSP keybindings
        vim.api.nvim_create_autocmd('LspAttach', {
          group = vim.api.nvim_create_augroup('UserLspConfig', {}),
          callback = function(ev)
            local opts = { buffer = ev.buf }
            vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
            vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
            vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
            vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
            vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, opts)
            vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
            vim.keymap.set({ 'n', 'v' }, '<leader>ca', vim.lsp.buf.code_action, opts)
            vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
            vim.keymap.set('n', '<leader>f', function()
              vim.lsp.buf.format { async = true }
            end, opts)
          end,
        })
        
        -- Treesitter configuration
        require'nvim-treesitter.configs'.setup {
          highlight = { enable = true },
          indent = { enable = true },
        }
        
        -- File explorer
        require('nvim-tree').setup()
        vim.keymap.set('n', '<leader>e', '<cmd>NvimTreeToggle<CR>')
        
        -- Status line
        require('lualine').setup({
          options = { theme = 'kanagawa' }
        })
        
        -- Git signs
        require('gitsigns').setup()
        
        -- Auto pairs
        require('nvim-autopairs').setup()
        
        -- Which-key
        require('which-key').setup()
        
        -- Alpha dashboard
        local alpha = require("alpha")
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
          dashboard.button("q", "  Quit", ":qa <CR>"),
        }
        
        -- Add startup time tracking
        vim.g.start_time = vim.fn.reltime()
        
        -- Footer with Kanagawa quote and load time
        local function get_load_time()
          if vim.g.start_time then
            local end_time = vim.fn.reltime()
            local elapsed = vim.fn.reltimefloat(vim.fn.reltime(vim.g.start_time, end_time))
            local ms = elapsed * 1000
            return "⚡ Neovim loaded in " .. string.format("%.2f", ms) .. "ms"
          else
            return "⚡ Neovim loaded successfully"
          end
        end
        
        dashboard.section.footer.val = function()
          return {
            "",
            get_load_time(),
            "",
            "The Great Wave off Kanagawa inspires this colorful journey",
            "~ Katsushika Hokusai ~",
          }
        end
        
        -- Custom highlighting to match Kanagawa theme
        dashboard.section.header.opts.hl = "AlphaHeader"
        dashboard.section.buttons.opts.hl = "AlphaButtons" 
        dashboard.section.footer.opts.hl = "AlphaFooter"
        
        -- Set custom highlight groups after colorscheme is loaded
        vim.api.nvim_create_autocmd("ColorScheme", {
          pattern = "kanagawa*",
          callback = function()
            -- Header: Use Kanagawa spring violet
            vim.api.nvim_set_hl(0, "AlphaHeader", { fg = "#957fb8" })
            -- Buttons: Use Kanagawa crystal blue  
            vim.api.nvim_set_hl(0, "AlphaButtons", { fg = "#7e9cd8" })
            -- Footer: Use Kanagawa fuji gray
            vim.api.nvim_set_hl(0, "AlphaFooter", { fg = "#727169", italic = true })
          end,
        })
        
        -- Setup alpha
        alpha.setup(dashboard.opts)
        
        -- Disable folding on alpha buffer
        vim.cmd([[
          autocmd FileType alpha setlocal nofoldenable
        ]])
        EOF
      '';
    };
  };
}

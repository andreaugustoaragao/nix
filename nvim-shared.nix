{ config, pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
    
    plugins = with pkgs.vimPlugins; [
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
    
    extraLuaConfig = ''
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
      
      -- Basic settings (LazyVim-style)
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
      
      -- System clipboard integration (LazyVim default)
      vim.opt.clipboard = "unnamedplus"
      
      -- Manual clipboard provider configuration for Wayland
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
      
      -- Better search behavior
      vim.opt.inccommand = "nosplit"
      
      -- Better completion
      vim.opt.completeopt = "menu,menuone,noselect"
      vim.opt.pumheight = 10
      
      -- Better file handling
      vim.opt.confirm = true
      vim.opt.undofile = true
      vim.opt.undolevels = 10000
      vim.opt.backup = false
      vim.opt.writebackup = false
      vim.opt.swapfile = false
      
      -- Better formatting
      vim.opt.formatoptions = "jcroqlnt"
      
      -- Better splits
      vim.opt.splitbelow = true
      vim.opt.splitright = true
      vim.opt.splitkeep = "screen"
      
      -- Better mouse support
      vim.opt.mouse = "a"
      vim.opt.mousemodel = "extend"
      
      -- Better visual feedback
      vim.opt.cursorline = true
      vim.opt.winminwidth = 5
      vim.opt.conceallevel = 0
      
      -- Better performance
      vim.opt.lazyredraw = false
      vim.opt.synmaxcol = 200
      
      -- Leader key
      vim.g.mapleader = " "
      vim.g.maplocalleader = "\\"
      
      -- LazyVim-style keybindings
      -- Better up/down movement for wrapped lines
      vim.keymap.set({ "n", "x" }, "j", "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })
      vim.keymap.set({ "n", "x" }, "k", "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })
      
      -- Move to window using the <ctrl> hjkl keys
      vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Go to left window", remap = true })
      vim.keymap.set("n", "<C-j>", "<C-w>j", { desc = "Go to lower window", remap = true })
      vim.keymap.set("n", "<C-k>", "<C-w>k", { desc = "Go to upper window", remap = true })
      vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Go to right window", remap = true })
      
      -- Resize window using <ctrl> arrow keys
      vim.keymap.set("n", "<C-Up>", "<cmd>resize +2<cr>", { desc = "Increase window height" })
      vim.keymap.set("n", "<C-Down>", "<cmd>resize -2<cr>", { desc = "Decrease window height" })
      vim.keymap.set("n", "<C-Left>", "<cmd>vertical resize -2<cr>", { desc = "Decrease window width" })
      vim.keymap.set("n", "<C-Right>", "<cmd>vertical resize +2<cr>", { desc = "Increase window width" })
      
      -- Move Lines
      vim.keymap.set("n", "<A-j>", "<cmd>m .+1<cr>==", { desc = "Move line down" })
      vim.keymap.set("n", "<A-k>", "<cmd>m .-2<cr>==", { desc = "Move line up" })
      vim.keymap.set("i", "<A-j>", "<esc><cmd>m .+1<cr>==gi", { desc = "Move line down" })
      vim.keymap.set("i", "<A-k>", "<esc><cmd>m .-2<cr>==gi", { desc = "Move line up" })
      vim.keymap.set("v", "<A-j>", ":m '>+1<cr>gv=gv", { desc = "Move line down" })
      vim.keymap.set("v", "<A-k>", ":m '<-2<cr>gv=gv", { desc = "Move line up" })
      
      -- Buffers
      vim.keymap.set("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
      vim.keymap.set("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next buffer" })
      vim.keymap.set("n", "[b", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
      vim.keymap.set("n", "]b", "<cmd>bnext<cr>", { desc = "Next buffer" })
      vim.keymap.set("n", "<leader>bb", "<cmd>e #<cr>", { desc = "Switch to Other Buffer" })
      vim.keymap.set("n", "<leader>`", "<cmd>e #<cr>", { desc = "Switch to Other Buffer" })
      
      -- Clear search with <esc>
      vim.keymap.set({ "i", "n" }, "<esc>", "<cmd>noh<cr><esc>", { desc = "Escape and clear hlsearch" })
      
      -- Better indenting
      vim.keymap.set("v", "<", "<gv")
      vim.keymap.set("v", ">", ">gv")
      
      -- Save file
      vim.keymap.set({ "i", "x", "n", "s" }, "<C-s>", "<cmd>w<cr><esc>", { desc = "Save file" })
      
      -- New file
      vim.keymap.set("n", "<leader>fn", "<cmd>enew<cr>", { desc = "New File" })
      
      -- Quit
      vim.keymap.set("n", "<leader>qq", "<cmd>qa<cr>", { desc = "Quit all" })
      
      -- Lazy
      vim.keymap.set("n", "<leader>l", "<cmd>Lazy<cr>", { desc = "Lazy" })
      
      -- Windows
      vim.keymap.set("n", "<leader>ww", "<C-W>p", { desc = "Other window", remap = true })
      vim.keymap.set("n", "<leader>wd", "<C-W>c", { desc = "Delete window", remap = true })
      vim.keymap.set("n", "<leader>w-", "<C-W>s", { desc = "Split window below", remap = true })
      vim.keymap.set("n", "<leader>w|", "<C-W>v", { desc = "Split window right", remap = true })
      vim.keymap.set("n", "<leader>-", "<C-W>s", { desc = "Split window below", remap = true })
      vim.keymap.set("n", "<leader>|", "<C-W>v", { desc = "Split window right", remap = true })
      
      -- tabs
      vim.keymap.set("n", "<leader><tab>l", "<cmd>tablast<cr>", { desc = "Last Tab" })
      vim.keymap.set("n", "<leader><tab>f", "<cmd>tabfirst<cr>", { desc = "First Tab" })
      vim.keymap.set("n", "<leader><tab><tab>", "<cmd>tabnew<cr>", { desc = "New Tab" })
      vim.keymap.set("n", "<leader><tab>]", "<cmd>tabnext<cr>", { desc = "Next Tab" })
      vim.keymap.set("n", "<leader><tab>d", "<cmd>tabclose<cr>", { desc = "Close Tab" })
      vim.keymap.set("n", "<leader><tab>[", "<cmd>tabprevious<cr>", { desc = "Previous Tab" })
      
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
      
      -- Telescope keybindings (LazyVim-style)
      local builtin = require('telescope.builtin')
      -- Find
      vim.keymap.set("n", "<leader>,", "<cmd>Telescope buffers show_all_buffers=true<cr>", { desc = "Switch Buffer" })
      vim.keymap.set("n", "<leader>/", "<cmd>Telescope live_grep<cr>", { desc = "Grep (root dir)" })
      vim.keymap.set("n", "<leader>:", "<cmd>Telescope command_history<cr>", { desc = "Command History" })
      vim.keymap.set("n", "<leader><space>", "<cmd>Telescope find_files<cr>", { desc = "Find Files (root dir)" })
      -- find
      vim.keymap.set("n", "<leader>fb", "<cmd>Telescope buffers<cr>", { desc = "Buffers" })
      vim.keymap.set("n", "<leader>fc", "<cmd>Telescope find_files cwd=false<cr>", { desc = "Find Files (cwd)" })
      vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files<cr>", { desc = "Find Files (root dir)" })
      vim.keymap.set("n", "<leader>fF", "<cmd>Telescope find_files hidden=true no_ignore=true<cr>", { desc = "Find Files (all)" })
      vim.keymap.set("n", "<leader>fg", "<cmd>Telescope live_grep<cr>", { desc = "Grep (root dir)" })
      vim.keymap.set("n", "<leader>fG", "<cmd>Telescope live_grep cwd=false<cr>", { desc = "Grep (cwd)" })
      vim.keymap.set("n", "<leader>fh", "<cmd>Telescope help_tags<cr>", { desc = "Help Pages" })
      vim.keymap.set("n", "<leader>fH", "<cmd>Telescope highlights<cr>", { desc = "Search Highlight Groups" })
      vim.keymap.set("n", "<leader>fk", "<cmd>Telescope keymaps<cr>", { desc = "Key Maps" })
      vim.keymap.set("n", "<leader>fl", "<cmd>Telescope loclist<cr>", { desc = "Location List" })
      vim.keymap.set("n", "<leader>fM", "<cmd>Telescope man_pages<cr>", { desc = "Man Pages" })
      vim.keymap.set("n", "<leader>fm", "<cmd>Telescope marks<cr>", { desc = "Jump to Mark" })
      vim.keymap.set("n", "<leader>fo", "<cmd>Telescope vim_options<cr>", { desc = "Options" })
      vim.keymap.set("n", "<leader>fR", "<cmd>Telescope resume<cr>", { desc = "Resume" })
      vim.keymap.set("n", "<leader>fq", "<cmd>Telescope quickfix<cr>", { desc = "Quickfix List" })
      vim.keymap.set("n", "<leader>fw", "<cmd>Telescope grep_string word_match=-w<cr>", { desc = "Word (root dir)" })
      vim.keymap.set("n", "<leader>fW", "<cmd>Telescope grep_string cwd=false word_match=-w<cr>", { desc = "Word (cwd)" })
      vim.keymap.set("v", "<leader>fw", "<cmd>Telescope grep_string<cr>", { desc = "Selection (root dir)" })
      vim.keymap.set("v", "<leader>fW", "<cmd>Telescope grep_string cwd=false<cr>", { desc = "Selection (cwd)" })
      
      -- LSP configuration
      local lspconfig = require('lspconfig')
      
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
      
      -- Python LSP (Pyright)
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
      
      -- Diagnostics configuration
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
      
      -- Diagnostics keybindings (LazyVim-style)
      local diagnostic_goto = function(next, severity)
        local go = next and vim.diagnostic.goto_next or vim.diagnostic.goto_prev
        severity = severity and vim.diagnostic.severity[severity] or nil
        return function()
          go({ severity = severity })
        end
      end
      vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line Diagnostics" })
      vim.keymap.set("n", "]d", diagnostic_goto(true), { desc = "Next Diagnostic" })
      vim.keymap.set("n", "[d", diagnostic_goto(false), { desc = "Prev Diagnostic" })
      vim.keymap.set("n", "]e", diagnostic_goto(true, "ERROR"), { desc = "Next Error" })
      vim.keymap.set("n", "[e", diagnostic_goto(false, "ERROR"), { desc = "Prev Error" })
      vim.keymap.set("n", "]w", diagnostic_goto(true, "WARN"), { desc = "Next Warning" })
      vim.keymap.set("n", "[w", diagnostic_goto(false, "WARN"), { desc = "Prev Warning" })
      
      -- LSP keybindings (LazyVim-style)
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('UserLspConfig', {}),
        callback = function(ev)
          local opts = { buffer = ev.buf }
          vim.keymap.set('n', 'gd', function() require("telescope.builtin").lsp_definitions({ reuse_win = true }) end, { desc = "Goto Definition", buffer = ev.buf })
          vim.keymap.set('n', 'gr', "<cmd>Telescope lsp_references<cr>", { desc = "References", buffer = ev.buf })
          vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, { desc = "Goto Declaration", buffer = ev.buf })
          vim.keymap.set('n', 'gI', function() require("telescope.builtin").lsp_implementations({ reuse_win = true }) end, { desc = "Goto Implementation", buffer = ev.buf })
          vim.keymap.set('n', 'gy', function() require("telescope.builtin").lsp_type_definitions({ reuse_win = true }) end, { desc = "Goto T[y]pe Definition", buffer = ev.buf })
          vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = "Hover", buffer = ev.buf })
          vim.keymap.set('n', 'gK', vim.lsp.buf.signature_help, { desc = "Signature Help", buffer = ev.buf })
          vim.keymap.set('i', '<C-k>', vim.lsp.buf.signature_help, { desc = "Signature Help", buffer = ev.buf })
          vim.keymap.set({ 'n', 'v' }, '<leader>ca', vim.lsp.buf.code_action, { desc = "Code Action", buffer = ev.buf })
          vim.keymap.set('n', '<leader>cc', vim.lsp.codelens.run, { desc = "Run Codelens", buffer = ev.buf })
          vim.keymap.set('n', '<leader>cC', vim.lsp.codelens.refresh, { desc = "Refresh & Display Codelens", buffer = ev.buf })
          vim.keymap.set('n', '<leader>cr', vim.lsp.buf.rename, { desc = "Rename", buffer = ev.buf })
          vim.keymap.set("n", "<leader>cf", function()
            vim.lsp.buf.format({ async = true })
          end, { desc = "Format Document", buffer = ev.buf })
          vim.keymap.set("v", "<leader>cf", function()
            vim.lsp.buf.format({ async = true })
          end, { desc = "Format Range", buffer = ev.buf })
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
    '';
  };
}


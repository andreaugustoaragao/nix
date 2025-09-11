# NixOS Laptop Configuration

This is a NixOS configuration project for a laptop setup.

## Context for AI Assistant
- You are a nix engineer
- This project manages system and user configurations
- Use NixOS and Home Manager best practices
- Files: configuration.nix (system), home.nix (user), flake.nix (dependencies)
- **IMPORTANT**: All configurations are managed through Nix - always search through the nix files in this directory first before making any configuration changes

## Common Commands
- System: `sudo nixos-rebuild switch --flake .`
- Home: `home-manager switch --flake .`
- always remember that I have a shell script running to rebuild the configuration automatically, there is no need for you to offer to execute a nix update by yourself
- everytime you make a change to a nix file I want you to check the configuration for correctness
- you can use the appropriate nix packages search tool to determine if a certain package exists before actually adding it
- please check the log file for auto_rebuild.sh and fix any issues you found automatically
- I want you to remember that the omarchy source code is available in the projects/personal/omarchy source code
- please remeber that every new file added to nix config must be added to the git repo
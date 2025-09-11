{ config, pkgs, lib, inputs, ... }:

{
  # Git configuration
  programs.git = {
    enable = true;
    userName = "aragao";
    userEmail = "your-email@example.com";  # Update with your email
  };
} 
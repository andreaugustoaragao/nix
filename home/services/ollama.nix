{ config, pkgs, lib, inputs, ... }:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in

{
  # Ollama service configuration for Home Manager
  systemd.user.services.ollama = {
    Unit = {
      Description = "Ollama AI model server";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    
    Service = {
      Type = "exec";
      ExecStart = "${unstable-pkgs.ollama}/bin/ollama serve";
      Environment = [
        "OLLAMA_HOST=127.0.0.1:11434"
        "OLLAMA_MODELS=${config.home.homeDirectory}/.ollama/models"
      ];
      Restart = "on-failure";
      RestartSec = "5s";
    };
    
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
  
  # Create ollama models directory
  home.file.".ollama/models/.keep".text = "";
  
  # Environment variables for ollama
  home.sessionVariables = {
    OLLAMA_HOST = "127.0.0.1:11434";
  };
}
  oh-my-zsh = {
    enable = true;
    plugins = [ "git" "sudo" "docker" "kubectl" ];
    theme = "robbyrussell";
  };

  initContent = ''
    export GOPATH="$HOME/go"
    export GOBIN="$GOPATH/bin"
    export PATH="$GOBIN:$PATH"
  ''; 
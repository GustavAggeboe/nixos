{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  inherit (builtins)
    mapAttrs
    ;
  inherit (pkgs.stdenv.hostPlatform)
    system
    ;

  cfg = config.swag.tui;

  # ANSI escape codes for changing colors of terminal text.
  # https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124
  colors = mapAttrs (name: value: ''\[\x1b[${value}m\]'') {
    red = "1;31";
    green = "1;32";
    orange = "1;33";
    cyan = "1;36";
  };

  # Unicode escape sequences for symbols for proper character width when printed.
  symbols = {
    "€" = ''\U000020AC'';
    "£" = ''\U000000A3'';
  };

  mkPS1 =
    mainColor: symbol:
    let
      # Adds name of Nix shell to PS1, if in one.
      devShell = "\${name:+${colors.cyan}[$name]${mainColor} }";

      # Adds name of hostname if connected through SSH.
      hostname = "\${SSH_CONNECTION:+${colors.orange}@$HOSTNAME${mainColor}}";

      # Don't end with '\]', or color messes up on line-wrap. This only occurs
      # when including a unicode character longer than 1 byte.
      # Omitting it avoids this, and we really don't need to end the no-width
      # escape sequence here, as there are no more printed characters in the PS1
      # after colors are reset at the end.
      resetColors = ''\[\x1b[0m'';
    in
    # Expand escape and unicode characters and by using a $'' string.
    "$'${mainColor}\\u${hostname} ${devShell}\\w ${symbol} ${resetColors}'";

  promptInit = ''
    # Set red prompt only for root.
    case "$EUID" in
      0) PS1=${mkPS1 colors.red symbols."£"};;
      *) PS1=${mkPS1 colors.green symbols."€"};;
    esac

    function y {
    	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
    	command yazi "$@" --cwd-file="$tmp"
    	IFS= read -r -d "" cwd < "$tmp"
    	[[ $cwd != "$PWD" ]] && [[ -d "$cwd" ]] && builtin cd -- "$cwd"
    	command rm -f -- "$tmp"
    }
  '';

  # Quick shortcuts.
  shellAliases = {
    zj = "zellij";
    lg = "lazygit";
    ff = "fastfetch";
    cdgit = "cd ~/Documents/git";
    cdtemp = "cd $(mktemp -d)";
    pipes = "pipes.sh -t 0 -c 1 -c 2 -c 3 -c 4 -c 5 -c 6 -c";
  };
in
{
  options.swag.tui = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    editor = lib.mkOption {
      type = lib.types.str;
      default = "hx";
    };

    usePatchedPrograms = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # TUI file manager / filesystem navigator.
    programs.yazi.enable = true;

    environment.systemPackages =
      with pkgs;
      [
        # TUI git manager.
        lazygit

        # ISO image burner.
        caligula

        # Fluff.
        fastfetch
        pipes
        btop
      ]
      ++ lib.optionals (cfg.usePatchedPrograms) [
        # Pseudo-ide combo.
        self.packages.${system}.zellij
        self.packages.${system}.helix
      ]
      ++ lib.optionals (!cfg.usePatchedPrograms) [
        zellij
        helix
      ];

    # Add shell aliases.
    programs.bash = { inherit promptInit shellAliases; };

    # Set Helix as default editor.
    environment.variables = {
      EDITOR = cfg.editor;
    };
  };
}

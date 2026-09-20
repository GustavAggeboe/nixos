{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.swag.default-nixos;

  shellAliases = {
    # Update.
    ud = "sudo $SHELL -c 'cd /etc/nixos; git fetch; git rebase --autostash'";

    # Rebuild.
    rb = "sudo nixos-rebuild switch --flake /etc/nixos";

    # 'Edit flake'. Go to /etc/nixos as root.
    ef = "$SHELL -c 'cd /etc/nixos; sudo --preserve-env --shell'";

    # Nix commands.
    nd = "nix develop";
    ni = "nix-index";
    nl = "nix-locate";
  };

  promptInit = ''
    # Shorthand for `nix shell nixpkgs#$1 nixpkgs#$2 ...`.
    function ns {
      if [[ $# == 0 ]]; then
        return
      fi

      declare -a nsCommand=()

      if [[ ''${name:0:4} == "ns: " ]]; then
        nsName="''$name, "
      else
        first=1
        nsName="ns: "
      fi

      function add-arg-to-commands {
        # Check if package is already in use.
        if [[ "$name" =~ " "''${1}(,|$) ]]; then
          return
        fi

        # Don't append arg name to 'nixpkgs#', if it a flag.
        if [[ ''${1:0:1} == "-" ]]; then
          nsCommand+=("$1")
        # Don't append arg name to 'nixpkgs#', if it has a hashtag.
        elif [[ "$1" =~ "#" ]]; then
          nsCommand+=("$1")
          nsName+="$([[ ! first ]] && printf ', ')$1"
        else
          nsCommand+=("nixpkgs#$1")
          nsName+="$([[ ! first ]] && printf ', ')$1"
        fi
      }

      for arg in "''${@:1:$#}"; do
        add-arg-to-commands "$arg"
      done
      
      if [[ ''${#nsCommand[@]} == 0 ]] then
        return
      fi

      name="$nsName" NIXPKGS_ALLOW_UNFREE=1 nix shell --impure ''${nsCommand[@]}
    }

    # What is the real path of this binary?
    function realwhich {
      echo $(realpath $(which $1))
    }

    # Go to directory of binary in the store.
    function godrv {
      cd $(dirname $(realwhich $1))
    }
  '';

  nixPath = "/etc/nixPath";
in
{
  options = {
    swag.default-nixos.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # NixOS store optimization and garbage collection.
    nix = {
      settings = {
        trusted-users = [ "thedb" ];
        auto-optimise-store = true;
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        keep-derivations = true;
        keep-outputs = true;
        download-attempts = 3;
        connect-timeout = 3;
      };
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 14d";
      };
      # Make the nix-daemon much nicer.
      daemonCPUSchedPolicy = "idle";
      daemonIOSchedClass = "idle";
      daemonIOSchedPriority = 7;
    };

    systemd.services."fetch-nixpkgs-tarball-on-startup" = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = pkgs.writeShellScript "fetch-nixpkgs-tarball" ''
          exec ${pkgs.nix}/bin/nix run nixpkgs#hello
        '';
      };
    };

    # Set nix channel to follow system flake nixpkgs input.
    nix.nixPath = [ "nixpkgs=${nixPath}" ];
    systemd.tmpfiles.rules = [
      "L+ ${nixPath} - - - - ${pkgs.path}"
    ];

    nixpkgs.config.allowUnfree = true;

    # Useful Nix commands.
    environment = {
      systemPackages = with pkgs; [
        nix-search-cli
        nix-index
      ];
      variables = {
        NIXPKGS_REV = "${inputs.nixpkgs.rev}";
      };
    };

    programs.direnv = {
      enable = true;
      package = pkgs.direnv;
      silent = true;
      nix-direnv = {
        enable = true;
        package = pkgs.nix-direnv;
      };
    };

    # Bash aliases.
    programs.bash = { inherit promptInit shellAliases; };
  };
}

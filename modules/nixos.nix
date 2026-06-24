{ inputs, pkgs, ... }:

let
  shellAliases = {
    # Update.
    ud = "sudo /usr/bin/env sh -c 'cd /etc/nixos; git pull --ff-only'";

    # Rebuild.
    rb = "sudo nixos-rebuild switch --flake /etc/nixos";

    # 'Edit flake'. Go to /etc/nixos as root.
    ef = "/usr/bin/env sh -c 'cd /etc/nixos; sudo -E su'";

    # Nix commands.
    nd = "nix develop";
    ni = "nix-index";
    nl = "nix-locate";

  };

  shellInit = ''
    # Shorthand for `nix shell nixpkgs#$1 nixpkgs#$2 ...`.
    ns() {
      ORIGINAL_NAME="$name"
      local NIX_SHELL="NIXPKGS_ALLOW_UNFREE=1 nix shell --impure"
      if [[ "$@" == "" ]]; then
        return
      fi
      name='ns'
      for arg in "$@"; do
        NIX_SHELL+=" nixpkgs#$arg"
        name+="-$arg"
      done
      export name=$name && (eval "$NIX_SHELL" || export name=$ORIGINAL_NAME)
      export name=$ORIGINAL_NAME
    }

    # What is the real path of this binary?
    realwhich() {
      echo $(realpath $(which $1))
    }

    # Go to directory of binary in the store.
    godrv() {
      cd $(dirname $(realwhich $1))
    }
  '';

  nixPath = "/etc/nixPath";
in
{
  # NixOS store optimization and garbage collection.
  nix = {
    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      keep-derivations = true;
      keep-outputs = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  systemd.services."fetch-nixpkgs-tarball-on-startup" = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "fetch-nixpkgs-tarball" ''
        exec ${pkgs.nix}/bin/nix run ${pkgs.path}#hello
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
    enable = false;
    package = pkgs.direnv;
    silent = true;
    nix-direnv = {
      enable = true;
      package = pkgs.nix-direnv;
    };
  };

  # Bash aliases.
  programs.bash = { inherit shellInit shellAliases; };
}

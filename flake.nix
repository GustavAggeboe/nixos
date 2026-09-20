{
  description = "Home of my configuration files.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hytale-flake = {
      url = "github:swagtop/hytale-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Windows-style mouse acceleration kernel module (see modules/mouse.nix).
    # Its flake exposes only nixosModules.default and declares no `nixpkgs`
    # input to follow; the kernel module is built against this system's kernel.
    maccel.url = "github:Gnarus-G/maccel";
    # Official Claude desktop app (Chat, Cowork, Code) repackaged for Nix.
    claude-desktop = {
      url = "github:nmcbride/claude-desktop-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      lanzaboote,
      hytale-flake,
      ...
    }:
    let
      inherit (builtins)
        foldl'
        path
        ;

      inherit (nixpkgs.lib)
        mapAttrs
        mapAttrs'
        readDir
        removeSuffix
        ;

      swaglib = import ./lib.nix;

      inherit (swaglib)
        importDirectory
        ;

      patches = mapAttrs' (name: value: {
        name = removeSuffix ".patch" name;
        value = path {
          inherit name;
          path = ./patches/${name};
        };
      }) (readDir ./patches);

      perSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          packages = import ./packages (pkgs // { inherit patches swaglib; });
          formatter = pkgs.nixfmt-tree;
        };

      flake = {
        nixosConfigurations =
          let
            mapHosts = mapAttrs (
              name: host:
              nixpkgs.lib.nixosSystem (
                host
                // {
                  specialArgs = host.specialArgs or { } // {
                    inherit
                      inputs
                      patches
                      self
                      swaglib
                      ;
                  };

                  modules = host.modules or [ ] ++ [
                    ./hosts/${name}/configuration.nix
                    (importDirectory { dir = ./modules/core; })
                  ];
                }
              )
            );
          in
          mapHosts {
            aggepc = {
              modules = [
                ./modules/mouse.nix

                # Claude desktop app. Cowork's sandbox VM needs /dev/kvm,
                # hence kvmUsers.
                inputs.claude-desktop.nixosModules.default
                {
                  programs.claude-desktop = {
                    enable = true;
                    cowork.kvmUsers = [ "gustav" ];
                  };
                }
              ];
            };
            gamebeast = {
              modules = [
                ./modules/dev.nix
                ./modules/gaming.nix
                ./modules/gui.nix
                ./modules/music.nix
                ./modules/office.nix
                hytale-flake.nixosModules.hytale-launcher
              ];
            };
            duster = {
              modules = [
                ./modules/dev.nix
                ./modules/gui.nix
                lanzaboote.nixosModules.lanzaboote
              ];
            };
            files = { };
            builder = { };
          };
      };
    in
    foldl' (
      acc: system:
      let
        mergeSystem = name: value: acc.${name} or { } // { ${system} = value; };
      in
      acc // mapAttrs mergeSystem (perSystem system)
    ) flake nixpkgs.lib.systems.flakeExposed;
}

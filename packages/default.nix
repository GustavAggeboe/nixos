{
  pkgs,
  lib,
  patches,
  swaglib,
  ...
}:
let
  inherit (pkgs.lib)
    concatStringsSep
    ;

  inherit (swaglib)
    safeOverride
    ;

  symlinkWrap =
    {
      package,
      execName,
      args,
    }:
    pkgs.symlinkJoin {
      name = "${package.name}-thru-overlay";
      paths = [ package ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/${execName} ${concatStringsSep " " args};
      '';
      passthru.meta.mainProgram = execName;
    };

  helix =
    let
      configFile = pkgs.stdenvNoCC.mkDerivation {
        name = "helix-config.toml";
        src = ../configs/helix/config.toml;
        phases = [ "installPhase" ];

        # Make sure config is pointing to theme in store.
        installPhase = ''
          cp $src $out
          substituteInPlace $out --replace "cool-theme" "${../configs/helix/themes}/cool-theme"
        '';
      };
    in
    symlinkWrap {
      package = pkgs.helix.override (old: {
        helix-unwrapped = old.helix-unwrapped.overrideAttrs (safeOverride {
          patches = [ patches.helix-upppercase-commands ];
        });
      });
      execName = "hx";
      args = [
        "--add-flags \"--config ${configFile}\""
      ];
    };

  zellij = symlinkWrap {
    package = pkgs.zellij;
    execName = "zellij";
    args = [
      "--add-flags \"-c ${../configs/zellij/config.kdl}\""
    ];
  };
in
{
  inherit helix zellij;

  install = pkgs.callPackage (import ./install.nix) { };

  locd = pkgs.callPackage (import ./locd.nix) { };

  ide = pkgs.writeShellApplication {
    name = "ide";
    runtimeInputs = [
      helix
      pkgs.lazygit
      pkgs.git
      pkgs.gh
    ];
    text = ''
      exec ${zellij}/bin/zellij "$@"
    '';
  };

  # Music production things.
  bitwig-studio = symlinkWrap {
    package = pkgs.bitwig-studio5;
    execName = "bitwig-studio";
    args = [
      "--set LD_LIBRARY_PATH \"${
        lib.makeLibraryPath (
          with pkgs;
          [
            alsa-lib
            alsa-utils
            bitwig-studio
            curlWithGnuTls
            fontconfig
            freetype
            libGL
            libICE
            libsecret.out
            libSM
            libsndfile
            libudev0-shim
            libX11
            libXcursor
            libXext
            libXi
            libXrandr
            pkg-config
            udev
            vulkan-loader
            wayland
            wayland-protocols
            # wineWowPackages.yabridge
            xwayland
            zlib
          ]
        )
      }\""
    ];
  };

  # Gaming stuff.
  discord = (
    pkgs.discord.overrideAttrs (
      safeOverride (
        let
          flags = "${lib.concatStringsSep " " [
            "--ignore-gpu-blocklist"
            "--enable-features=UseOzonePlatform"
            "--ozone-platform=wayland"
            "--enable-features=VaapiVideoDecoder"
            "--use-gl=desktop"
            "--enable-gpu-rasterization"
            "--enable-zero-copy"
          ]}";
        in
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/discord --add-flags "${flags}"
            wrapProgram $out/bin/Discord --add-flags "${flags}"
          '';
        }
      )
    )
  );

  steam = pkgs.steam.overrideAttrs (safeOverride {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildCommand = ''
      wrapProgram $out/bin/steam --add-flags "steam://unlockh264";
    '';
  });

  alacritty = symlinkWrap {
    package = pkgs.alacritty;
    execName = "alacritty";
    args = [
      "--add-flags \"--config-file ${../configs/alacritty/alacritty.toml}\""
    ];
  };
}

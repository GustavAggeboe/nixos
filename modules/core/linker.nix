{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.swag.linker;
in
{
  options = {
    swag.linker = {
      enable = lib.mkEnableOption "Opt into the swag linker.";

      extraLibraries = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable dynamic linking.
    programs.nix-ld = {
      enable = true;
      libraries =
        with pkgs;
        [
          alsa-lib-with-plugins
          libGL
          libICE
          libSM
          libX11
          libXcursor
          libXext
          libXi
          libxkbcommon
          libxkbfile
          libXrandr
          pkg-config
          steam-run
          udev
          vulkan-loader
          wayland
          xwayland
        ]
        ++ cfg.extraLibraries;
    };
  };
}

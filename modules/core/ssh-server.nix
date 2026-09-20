{
  config,
  lib,
  ...
}:
let
  cfg = config.swag.ssh-server;
in
{
  options = {
    swag.ssh-server = {
      enable = lib.mkEnableOption "Enable SSH server.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ 22 ];
    services.openssh = {
      enable = true;
      extraConfig = ''
        AcceptEnv COLORTERM
      '';
    };
  };
}

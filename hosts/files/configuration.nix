# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mapAttrs;
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  swag.cache.enable = true;

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  networking.hostName = "files";
  networking.wireless.enable = lib.mkForce false;

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Copenhagen";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_DK.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "da_DK.UTF-8";
    LC_IDENTIFICATION = "da_DK.UTF-8";
    LC_MEASUREMENT = "da_DK.UTF-8";
    LC_MONETARY = "da_DK.UTF-8";
    LC_NAME = "da_DK.UTF-8";
    LC_NUMERIC = "da_DK.UTF-8";
    LC_PAPER = "da_DK.UTF-8";
    LC_TELEPHONE = "da_DK.UTF-8";
    LC_TIME = "da_DK.UTF-8";
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."thedb" = {
    isNormalUser = true;
    description = "thedb";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [ ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [ ];

  zramSwap.enable = true;

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      80
      443
    ];
    # allowedUDPPorts = [ ... ];
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "thedb11@gmail.com";
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts =
      mapAttrs
        (
          name: value:
          value
          // {
            forceSSL = true;
            enableACME = true;
          }
        )
        {
          "spirre.vip".locations."/".return = "301 https://www.spirre.vip$request_uri";
          "www.spirre.vip".locations."/f/".alias = "/srv/data/files/";

          "cache.spirre.vip".locations."/" = {
            proxyPass = "http://builder:5000";
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header http_version 1.1;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection $connection_upgrade;
            '';
          };

          "jf.spirre.vip".locations."/" = {
            proxyPass = "http://localhost:8096";
            proxyWebsockets = true;
          };
        };
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "files";
        "netbios name" = "files";
        "security" = "user";
        "hosts allow" = "10.10.10. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
        "guest account" = "nobody";
        "map to guest" = "Bad User";
      };
      "delemappppe" = {
        "path" = "/home/thedb/delemappe";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0666";
        "directory mask" = "0777";
        "force user" = "thedb";
        "force group" = "nogroup";
      };
    }
    //
      mapAttrs
        (
          name: value:
          value
          // {
            "browseable" = "yes";
            "read only" = "no";
            "guest ok" = "yes";
            "create mask" = "0666";
            "directory mask" = "0777";
            "force user" = "jellyfin";
            "force group" = "nogroup";
          }
        )
        {
          music.path = "/srv/data/media/music";
          movies.path = "/srv/data/media/movies";
          shows.path = "/srv/data/media/shows";
          books.path = "/srv/data/media/books";
        };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  services.jellyfin = {
    enable = true;
    dataDir = "/srv/data/media";
    hardwareAcceleration = {
      enable = true;
      type = "qsv";
      device = "/dev/dri/renderD128";
    };
    transcoding = {
      enableHardwareEncoding = true;
      enableIntelLowPowerEncoding = true;
    };
  };

  services.pumpkin = {
    enable = true;
    openFirewall = true;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?
}

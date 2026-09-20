{
  pkgs,
  native,
  lib,
  swaglib,
  config,
  ...
}:
{
  imports = [ ./hardware-configuration.nix ];

  swag = {
    cache.enable = true;
    # linker.enable = true;
  };

  programs.obs-studio = {
    enable = true;
    package = pkgs.obs-studio.override { cudaSupport = true; };
    plugins = with pkgs; [
      obs-studio-plugins.obs-pipewire-audio-capture
      obs-studio-plugins.obs-vaapi
    ];
  };

  # Compile all packages locally.
  # nix.settings.substitute = false;

  # Allow unfree packages.
  nixpkgs.config.allowUnfree = true;
  programs.nix-ld.enable = true;

  # Bootloader.
  boot.loader = {
    efi.canTouchEfiVariables = true;

    # To find out the 'efiDeviceHandle' value for 'windows', boot into this and
    # run 'map -c'. Run 'ls <device>:\EFI' per handle to look for the
    # 'Microsoft' directory. Use this handle for Windows.
    # systemd-boot.edk2-uefi-shell.enable = true;
    systemd-boot = {
      enable = true;
      windows = {
        "Windows" = {
          title = "Windows 11";
          sortKey = "0";
          efiDeviceHandle = "HD1b";
        };
      };
    };
  };

  # Set hostname.
  networking.hostName = "gamebeast";

  # Enables wireless support via wpa_supplicant.
  # networking.wireless.enable = true;

  # ZFS.
  boot.zfs = {
    package = native.zfs;
    forceImportRoot = false;
  };
  services.zfs.autoScrub.enable = true;
  networking.hostId = "8425e349";

  # Use latest kernel compatible with ZFS.
  boot.kernelPackages =
    let
      zfsKernelPackages = swaglib.latestZfsCompatible { inherit pkgs config; };

      customKernel = zfsKernelPackages.kernel.override {
        # Check current config with 'zcat /proc/config.gz'.
        ignoreConfigErrors = true;
        structuredExtraConfig =
          let
            inherit (pkgs.lib.kernel)
              yes
              no
              ;
          in
          {
            # Build AMDGPU into the kernel, instead of loading as module.
            DRM = yes;
            DRM_KMS_HELPER = yes;
            DRM_NOUVEAU = yes;
            FB_NVIDIA = yes;
            DRM_TTM = yes;
            FB = yes;

            # Disable graphics from other vendors.
            DRM_XE = no;
            DRM_AMDGPU = no;
            DRM_RADEON = no;
            DRM_ADP = no;
            DRM_MGAG200 = no;
            DRM_AST = no;

            # Disable industrial IO drivers.
            IIO = no;
          };
      };
    in
    zfsKernelPackages;

  system.replaceDependencies.replacements =
    let
      native-mutter = native.mutter.override {
        inherit (native) gtk4 gnome-desktop;
      };
    in
    [
      {
        original = pkgs.gnome-session;
        replacement = native.gnome-session.override {
          inherit (native) gnome-desktop;
        };
      }
      {
        original = pkgs.mutter;
        replacement = native-mutter;
      }
      {
        original = pkgs.gnome-shell;
        replacement = native.gnome-shell.override {
          inherit (native) gtk4 gjs gnome-desktop;
          mutter = native-mutter;
        };
      }
    ]
    ++
      map
        (name: value: {
          original = pkgs.${name};
          replacement = native.${name};
        })
        (
          builtins.attrNames {
            inherit (pkgs)
              gnome-desktop
              libdrm
              libgbm
              vulkan-loader
              ;
          }
        );

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking.
  networking.networkmanager.enable = true;

  nixpkgs.config.rocmSupport = true;

  services.displayManager.gdm.enable = true;
  services.desktopManager = {
    gnome.enable = true;
    # cosmic.enable = true;
  };

  services.auto-cpufreq.enable = true;
  services.power-profiles-daemon.enable = false;

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

  # Enable the X11 windowing system.
  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
  };
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
  };

  services.libinput.enable = true;
  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      nvidia-vaapi-driver
    ];
    enable32Bit = true;
    extraPackages32 = with pkgs.pkgsi686Linux; [
      intel-vaapi-driver
    ];
  };

  hardware.amdgpu.legacySupport.enable = true;

  environment.variables = {
    # Intel stuff
    LIBVA_DRIVER_NAME = "iHD";
  };

  environment.systemPackages = with pkgs; [
    libvirt
    freetype
    native.ripgrep
    # rocmPackages.rocm-smi # AMD GPU Monitoring
  ];

  services.udev.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "dk";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "dk-latin1";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;
  services.pipewire.enable = true;
  programs.dconf.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.thedb = {
    isNormalUser = true;
    description = "thedb";
    extraGroups = [
      "networkmanager"
      "wheel"
      "keyd"
      "realtime"
      "audio"
      "video"
      "libvirtd"
      "qemu-libvirtd"
      "nix"
    ];
    packages = with pkgs; [
      spotify
      transmission_4-gtk
      prismlauncher
    ];
  };

  virtualisation.docker = {
    enable = false;
    rootless = {
      enable = true;
      setSocketVariable = true;
      daemon.settings = {
        # dns = [ "10.10.10.1" ];
        registry-mirrors = [ "https://mirror.gcr.io" ];
      };
    };
  };

  # zramSwap.enable = true;

  # Install firefox.
  programs.firefox.enable = true;
  programs.firefox.package = pkgs.firefox-esr;

  # Some programs need SUID wrappers, can be configured further or are started
  # in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  programs.steam.localNetworkGameTransfers.openFirewall = true;

  # List services that you want to enable:
  programs.virt-manager = {
    enable = true;
    package = pkgs.virt-manager;
  };

  virtualisation = {
    libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        swtpm.enable = true;
        runAsRoot = false;
      };
    };
    spiceUSBRedirection.enable = true;
  };

  programs.ssh = {
    extraConfig = ''
      Host builder
        HostName builder
        ProxyJump hypervisor

      Host files
        HostName hypervisor
    '';
  };

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;
  services.dbus.enable = true;
  services.geoclue2.enable = lib.mkForce false;

  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings.main.capslock = "esc";
    };
  };

  # Flatpak and flathub, and adw-gtk3 theme for flatpaks.
  services.flatpak.enable = true;
  systemd.services.flatpak-repo = {
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.flatpak ];
    # script = ''
    #   flatpak remote-add --if-not-exists \
    #   flathub https://flathub.org/repo/flathub.flatpakrepo
    # '';
  };

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [
    8000
    # 16261
    # 16262
  ];
  networking.firewall.allowedUDPPorts = [
    # 16261
    # 16262
  ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.04"; # Did you read the comment?

  boot.blacklistedKernelModules = [ "radeon" ];

  # Sleep fixes.
  boot.kernelParams = [
    "mem_sleep_default=deep"
    "pcie_port_pm=off"
  ];

  # WiFi card fixes.
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0
    options iwlmvm power_scheme=1
    options iwlwifi d0i3_disable=1
    options iwlwifi uapsd_disable=1
  '';

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.eno1.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp4s0.useDHCP = lib.mkDefault true;
}

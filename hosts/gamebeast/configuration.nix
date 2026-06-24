{
  pkgs,
  lib,
  swaglib,
  config,
  ...
}:
let
  inherit (builtins)
    attrValues
    mapAttrs
    match
    tryEval
    ;

  optimizeForNative = swaglib.optimizeForNative pkgs "skylake";
in
{
  imports = [ ./hardware-configuration.nix ];

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
    edk2-uefi-shell.enable = true;
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
  boot.zfs.forceImportRoot = false;
  services.zfs.autoScrub.enable = true;
  networking.hostId = "8425e349";

  # Use latest kernel compatible with ZFS.
  boot.kernelPackages = pkgs.linuxPackagesFor (
    let
      zfsCompatibleKernelPackages = lib.filterAttrs (
        name: kernelPackages:
        (match "linux_[0-9]+_[0-9]+" name) != null
        && (tryEval kernelPackages).success
        && (!kernelPackages.${config.boot.zfs.package.kernelModuleAttribute}.meta.broken)
      ) pkgs.linuxKernel.packages;

      latestKernelPackage = lib.last (
        lib.sort (a: b: (lib.versionOlder a.kernel.version b.kernel.version)) (
          attrValues zfsCompatibleKernelPackages
        )
      );
    in
    optimizeForNative (
      latestKernelPackage.kernel.override {
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
            DRM_TTM = yes;
            DRM_AMDGPU = yes;
            FB = yes;

            # Disable graphics from other vendors.
            DRM_XE = no;
            DRM_RADEON = no;
            DRM_NOUVEAU = no;
            DRM_ADP = no;
            DRM_MGAG200 = no;
            DRM_AST = no;
            FB_NVIDIA = no;

            # Disable industrial IO drivers.
            IIO = no;
          };
      }
    )
  );

  nixpkgs.overlays = [
    # Building GNOME stuff with native optimizations.
    (
      final: prev:
      let
        # Only using native GTK4 and GJS for some derivations, too many packages
        # need to be compiled if these are native in general.
        native = {
          gtk4 = optimizeForNative prev.gtk4;
          gjs = optimizeForNative prev.gjs;
        };
      in
      mapAttrs (name: value: optimizeForNative value) {
        inherit (prev) gnome-desktop ripgrep;

        gnome-session = prev.gnome-session.override {
          inherit (final) gnome-desktop;
        };
        mutter = prev.mutter.override {
          inherit (native) gtk4;
          inherit (final) gnome-desktop;
        };
        gnome-shell = prev.gnome-shell.override {
          inherit (native) gtk4 gjs;
          inherit (final) mutter gnome-desktop;
        };
      }
    )
  ];

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
  services.xserver = {
    enable = true;
    videoDrivers = [
      "amdgpu"
      "modesetting"
    ];
  };

  services.libinput.enable = true;
  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vulkan-loader
      vulkan-validation-layers
      vulkan-extension-layer
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
  services.pipewire = {
    enable = true;
    # pulse.enable = true;

    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };
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

  boot.zswap.enable = true;

  # Install firefox.
  programs.firefox.enable = true;

  # Some programs need SUID wrappers, can be configured further or are started
  # in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  programs.steam = {
    localNetworkGameTransfers.openFirewall = true;
  };

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

  services.mullvad-vpn.enable = true;

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

  # Needed for findings graphics card on boot.
  boot.initrd.kernelModules = [ "amdgpu" ];

  # A bunch of cool kernel parameters to make AMD R290 cooperate.
  boot.blacklistedKernelModules = [ "radeon" ];
  boot.kernelParams = [
    "radeon.cik_support=0"
    "radeon.si_support=0"
    "amdgpu.cik_support=1"
    "amdgpu.si_support=1"
    "amdgpu.dc=1"

    "intel_iommu=on"
    "amd_iommu=on"
    "iommu=pt"
    "vfio-pci.ids=1002:aac8"

    # Sleep fixes.
    "nohibernate"
    # "mem_sleep_default=deep"
    "acpi_sleep=nonvs"
    "pci=noaer"
  ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.eno1.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp4s0.useDHCP = lib.mkDefault true;
}

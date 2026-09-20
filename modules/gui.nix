{
  self,
  pkgs,
  lib,
  ...
}:

# Define preferred GNOME settings.
let
  gnomeSettings = [
    {
      settings = {
        "org/gnome/desktop/peripherals/keyboard" = {
          repeat-interval = lib.gvariant.mkUint32 30;
          delay = lib.gvariant.mkUint32 250;
        };
        "org/gnome/desktop/interface" = {
          enable-hot-corners = false;
          gtk-enable-primary-paste = false;
          gtk-theme = "adw-gtk3-dark";
          color-scheme = "prefer-dark";
        };
        "org/gnome/mutter" = {
          edge-tiling = true;
          experimental-features = [
            "scale-monitor-framebuffer"
            "xwayland-native-scaling"
          ];
        };
        "org/gnome/settings/daemon/plugins/color" = {
          night-light-enable = true;
        };
        "org/gnome/desktop/peripherals/mouse" = {
          speed = lib.gvariant.mkDouble "-1.0";
        };
        "org/gnome/desktop/background" = {
          primary-color = "#000000";
        };
        # "org/gnome/desktop/default-applications/terminal" = {
        #   exec = "alacritty";
        #   "exec-arg" = "--";
        # };
        # "org/gnome/desktop/applications/terminal" = {
        #   exec = "alacritty";
        #   exec-arg = "--";
        # };
      };
    }
  ];

  shellAliases = {
    # Open nautilus in current directory.
    naut = "nautilus .";
  };

  gstreamerPackages = with pkgs.gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ];
in
{
  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "alacritty";
  };
  # xdg.terminal-exec = {
  #   enable = true;
  #   package = self.packages.${pkgs.stdenv.hostPlatform.system}.alacritty;
  # };

  # Enable GNOME, GDM.
  services.displayManager.gdm = {
    enable = true;
    # wayland = true;
    # extraGSettingsOverrides = ''
    #   [org.gnome.mutter]
    #   experimental-features=['scale-monitor-framebuffer']
    # '';
  };
  services.desktopManager = {
    gnome.enable = true;
    # cosmic.enable = true;
  };
  programs.xwayland.enable = true;

  programs.sway = {
    enable = true;
    # Getting rid of pulseaudio and foot packages.
    extraPackages = with pkgs; [
      brightnessctl
      grim
      swayidle
      swaylock
      wmenu
    ];
  };
  programs.foot.enable = lib.mkForce false;

  # Use preferred GNOME settings.
  programs.dconf = {
    profiles = {
      user.databases = gnomeSettings;
      gdm.databases = gnomeSettings;
    };
  };

  environment.variables = {
    GNOME_SHELL_SLOWDOWN_FACTOR = "0.80";
    COLORTERM = "truecolor";
    TERM = "xterm-256color";
  };

  programs.ssh.extraConfig = ''
    SendEnv COLORTERM
    SendEnv TERM
  '';

  # Enable web browser.
  programs.firefox = {
    enable = true;
    wrapperConfig = {
      pipewireSupport = true;
    };
    preferences = {
      "media.hardware-video-decoding.force-enabled" = 1;
      "media.ffmpeg.vaapi.enabled" = 1;
      "media.navigator.mediadatadecoder_vp8_hardware_enabled" = 1;
      "media.videocontrols.picture-in-picture.enabled" = 0;
      "gfx.webrender.all" = 1;
    };
  };

  xdg.portal.enable = true;

  environment.systemPackages =
    with pkgs;
    [
      # Terminal emulator, wrapping in shell script for config.
      self.packages.${pkgs.stdenv.hostPlatform.system}.alacritty

      nautilus # For the 'nautilus-open-any-terminal' setup.
      element-desktop

      # Graphics.
      blender
      inkscape
      typst

      # Disk utility.
      gparted

      # Libadwaita theme for legacy GTK-3 applications.
      adw-gtk3

      # Media.
      celluloid

      # Wayland and other useful packages.
      wayland
      xwayland
      wayland-protocols
      linux-firmware
      ffmpeg
      gnome-boxes
      geary
    ]
    ++ gstreamerPackages;

  environment.sessionVariables.GST_PLUGIN_SYSTEM_PATH_1_0 =
    lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0"
      gstreamerPackages;

  services.mullvad-vpn = {
    enable = true;
    gui.enable = true;
  };

  programs.bash.shellAliases = shellAliases;

  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # Extra fonts.
  fonts.packages = with pkgs; [
    google-fonts
    nerd-fonts.hack
    nerd-fonts.caskaydia-cove
    nerd-fonts.caskaydia-mono
    nerd-fonts.recursive-mono
    nerd-fonts._0xproto
    texlivePackages.latex-fonts
  ];
}

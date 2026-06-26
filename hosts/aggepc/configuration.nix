# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:
let
  inherit (builtins)
    match
    tryEval
    attrValues
    ;
  # Save hook for the replay buffer: GSR can't name audio tracks itself, so
  # after each save we remux the clip (stream copy, no re-encode) and tag the
  # three tracks. MP4 can't store per-track titles, so recordings use MKV.
  gsrSaveScript = pkgs.writeShellScript "gsr-name-audio-tracks" ''
    # GSR runs this with: $1 = saved file path, $2 = type (replay/regular/screenshot).
    file="$1"
    type="$2"
    case "$type" in screenshot) exit 0 ;; esac
    tmp="$(dirname "$file")/.gsr-retitle.mkv"
    ${pkgs.ffmpeg-headless}/bin/ffmpeg -y -nostdin -v error -i "$file" \
      -map 0 -c copy -f matroska \
      -metadata:s:a:0 title="Mixed" \
      -metadata:s:a:1 title="Desktop" \
      -metadata:s:a:2 title="Microphone" \
      -disposition:a:0 default \
      -disposition:a:1 0 \
      -disposition:a:2 0 \
      "$tmp" && mv -f "$tmp" "$file"
  '';

  # The replay buffer records the mic from Easy Effects' virtual source
  # ("easyeffects_source") so the captured mic is noise-suppressed/processed
  # rather than raw. That node only exists once the easyeffects user service
  # has started and registered it with PipeWire. At login the replay service
  # can otherwise win the race and start before the node exists, silently
  # dropping the mic track — so poll (up to ~30s) until it appears first.
  gsrWaitForMic = pkgs.writeShellScript "gsr-wait-for-easyeffects-source" ''
    for _ in $(seq 1 60); do
      if ${pkgs.gpu-screen-recorder}/bin/gpu-screen-recorder --list-audio-devices \
           | ${pkgs.gnugrep}/bin/grep -q '^easyeffects_source|'; then
        exit 0
      fi
      sleep 0.5
    done
    echo "gsr-replay: easyeffects_source not found after timeout; starting anyway" >&2
    exit 0
  '';

  # nixpkgs' `rustdesk` (sciter) wrapper builds its GStreamer plugin path from
  # buildInputs and omits `pipewire` — so Wayland screen capture fails with
  # "Failed to create element from factory name" (missing `pipewiresrc`).
  # (`rustdesk-flutter` includes it, the legacy package doesn't.) Wrap the
  # already-built binary to add pipewire's gstreamer-1.0 dir to the plugin
  # path; the .desktop launcher uses `Exec=rustdesk` (PATH), so this also
  # applies when launched from the GNOME app grid.
  rustdesk-wayland = pkgs.symlinkJoin {
    name = "rustdesk-wayland-${pkgs.rustdesk.version}";
    paths = [ pkgs.rustdesk ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/rustdesk \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 ':' "${pkgs.pipewire}/lib/gstreamer-1.0"
    '';
  };
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader = {
    efi.canTouchEfiVariables = true;
    systemd-boot = {
      # To find out the 'efiDeviceHandle' value for 'windows', boot into this and
      # run 'map -c'. Run 'ls <device>:\EFI' per handle to look for the
      # 'Microsoft' directory. Use this handle for Windows.
      # edk2-uefi-shell.enable = true;
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


  networking.hostId = "8425e349";

  networking.hostName = "aggepc"; # Define your hostname.

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  services.xserver.enable = true;


  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Show minimize and maximize buttons on window titlebars (GNOME only shows
  # close by default).
  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close";
      };
    }
  ];

  environment.systemPackages = with pkgs; [
    helix
    vim
    git
    alsa-scarlett-gui
    easyeffects  # Audio effects (input noise suppression via RNNoise; tune in GUI)
    discord
    rustdesk-wayland  # Remote desktop client (pipewire gst plugin added for Wayland)
    jetbrains.idea  # IntelliJ IDEA Ultimate (swap to .idea-community for the free edition)
    nodejs  # provides node, npm and npx
    gnome-extension-manager  # "Extension Manager" — browse/install/toggle GNOME extensions

    # Screen recording / "instant replay" (AMD ReLive-style last-N-minutes
    # capture) using the GPU's hardware encoder (VAAPI). We capture the monitor
    # directly via KMS (`gpu-screen-recorder -w DP-1`) rather than through the
    # GNOME screencast portal (`-w portal`): on this GNOME 50 / Mutter Wayland +
    # AMD (Mesa 26.x) stack the portal feeds GSR all-black frames (audio fine,
    # video pure black) even though it reports a healthy capture framerate.
    # Direct KMS capture sidesteps the portal entirely and records real frames.
    # The `gpu-screen-recorder` package itself is installed via
    # `programs.gpu-screen-recorder.enable` below (which also sets up the
    # setcap wrapper for promptless recording).
    gpu-screen-recorder-gtk  # optional GTK GUI / tray frontend
    libva-utils              # `vainfo` — verify hardware encode works

    # GUI archive extraction. file-roller is GNOME's "Archive Manager"
    # (right-click → Extract in Files/Nautilus); p7zip is the CLI backend it
    # calls to handle .7z (and other) archives.
    file-roller
    p7zip
  ];

  # Install gpu-screen-recorder via its NixOS module rather than just dropping
  # the package in systemPackages: the module additionally creates a setcap
  # wrapper for `gsr-kms-server` (cap_sys_admin) enabling promptless, direct
  # KMS capture. The rolling replay buffer still needs the systemd user
  # service below — there is no upstream option for an always-on replay buffer.
  #
  # `-restart-replay-on-save yes` clears the rolling buffer on every save, so
  # back-to-back saves don't overlap: if you save, then save again a minute
  # later, the second clip is only ~1 minute long (just the new footage) rather
  # than another full 5 minutes that re-includes the first clip.
  programs.gpu-screen-recorder.enable = true;

  # "Instant replay" as a background user service: keeps a rolling 5-minute
  # buffer running for the whole graphical session. KMS capture needs no portal
  # permission prompt (the gsr-kms-server setcap wrapper grants the access), so
  # the service starts silently on every login. `-w DP-1` captures the monitor
  # we want; the other one is `DP-2` (see `gpu-screen-recorder --list-monitors`).
  # Save the last 5 minutes any time with (Alt+F10 is bound to this via a GNOME
  # custom keybinding in dconf):
  #   systemctl --user kill --kill-whom=main -s SIGUSR1 gsr-replay.service
  # NOTE: --kill-whom=main is required. Without it, systemd signals every
  # process in the unit's cgroup, so SIGUSR1 also hits the gsr-kms-server helper
  # child and breaks KMS capture ("failed to get kms ... no drm found"), after
  # which all saves silently produce nothing. The flag targets only the main
  # gpu-screen-recorder process, which is what interprets SIGUSR1 as "save".
  systemd.user.services.gsr-replay = {
    description = "GPU Screen Recorder — rolling 5-minute replay buffer";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    # Start after easyeffects so its "easyeffects_source" mic node exists; the
    # gsrWaitForMic ExecStartPre below additionally waits for the node to be
    # registered (the service is "started" the moment the process forks, before
    # the PipeWire node is up).
    after = [ "graphical-session.target" "easyeffects.service" ];
    wants = [ "easyeffects.service" ];
    serviceConfig = {
      ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p %h/Videos"
        "${gsrWaitForMic}"
      ];
      # The mic tracks use "easyeffects_source" (Easy Effects' processed virtual
      # source) instead of "default_input", so recordings get the noise-
      # suppressed mic. Track layout: Mixed (desktop+mic), Desktop, Microphone.
      ExecStart = "${pkgs.gpu-screen-recorder}/bin/gpu-screen-recorder -w DP-1 -c mkv -k hevc -f 60 -r 300 -restart-replay-on-save yes -a \"default_output|easyeffects_source\" -a default_output -a easyeffects_source -sc ${gsrSaveScript} -o %h/Videos/";
      # Retry if the portal/PipeWire isn't ready yet at login.
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Autostart Easy Effects in the background on login so its effects (input
  # noise suppression via RNNoise, etc.) are applied without opening the GUI.
  # The `easyeffects` package ships neither a systemd user unit nor an XDG
  # autostart entry, so nothing launched it before — installing the package
  # alone only put it in the app menu. `--gapplication-service` runs it
  # headless (no window), loading the last-used preset/state from the GUI.
  systemd.user.services.easyeffects = {
    description = "Easy Effects — audio effects daemon (background service)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.easyeffects}/bin/easyeffects --gapplication-service";
      ExecStop = "${pkgs.easyeffects}/bin/easyeffects --quit";
      # PipeWire may not be ready yet at login; retry until it is.
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  programs.firefox.enable = true;
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };

  users.users.gustav = {
    isNormalUser = true;
    description = "gustav";
    extraGroups = [
      "wheel"
      "nix"
    ];
    packages = with pkgs; [ ];
  };

  # Do not touch, as long as you are using ZFS.
  boot.zfs.forceImportRoot = false;
  boot.kernelPackages =
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
    pkgs.linuxPackagesFor latestKernelPackage.kernel;


  virtualisation.docker = {
    enable = true;
    # rootless = {
    #   enable = true;
    #   setSocketVariable = true;
    #   daemon.settings = {
    #     # dns = [ "10.10.10.1" ];
    #     registry-mirrors = [ "https://mirror.gcr.io" ];
    #   };
    # };
  };

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound with pipewire.
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;

    # The Focusrite Clarett+ 8Pre exposes its 10 outputs as positionless
    # AUX0..AUX9 channels. Native Linux apps (Discord/Firefox) remap stereo
    # onto AUX0/AUX1 fine, but Wine/Proton can't open a device that advertises
    # no FL/FR pair, so games get no audio. Relabel the first two channels as
    # FL/FR (same physical outputs 1/2) so every app — including games — uses
    # this one device. The other 8 channels stay available.
    wireplumber.extraConfig."99-clarett-stereo" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            { "node.name" = "alsa_output.usb-Focusrite_Clarett__8Pre_00011584-00.multichannel-output"; }
          ];
          actions.update-props = {
            "audio.position" =
              [ "FL" "FR" "AUX2" "AUX3" "AUX4" "AUX5" "AUX6" "AUX7" "AUX8" "AUX9" ];
            # Push the raw 10-channel sink to the bottom of the device list so
            # it's never auto-selected; the "Clarett+ 8Pre" loopback below wins.
            "priority.session" = 100;
            "priority.driver" = 100;
          };
        }
        {
          # The capture side needs no loopback (nothing requires a stereo input);
          # there's only the one source, so just rename it to match the output.
          matches = [
            { "node.name" = "alsa_input.usb-Focusrite_Clarett__8Pre_00011584-00.multichannel-input"; }
          ];
          actions.update-props."node.description" = "Clarett+ 8Pre";
        }
      ];
    };

    # Wine/Proton won't open the Clarett directly even with FL/FR labels: it's a
    # 10-channel device and FAudio wants a plain stereo sink (verified — relabel
    # alone leaves games silent). Expose a genuine 2-channel "Game Stereo" sink
    # and forward it to the Clarett's FL/FR (outputs 1/2, which the relabel above
    # provides). Set this as the default output and every app — Discord, Firefox,
    # games — funnels through it to the same physical outputs.
    extraConfig.pipewire."99-game-stereo" = {
      "context.modules" = [
        {
          name = "libpipewire-module-loopback";
          args = {
            "node.description" = "Clarett+ 8Pre";
            "capture.props" = {
              "node.name" = "game_stereo";
              "node.description" = "Clarett+ 8Pre";
              "media.class" = "Audio/Sink";
              "audio.position" = [ "FL" "FR" ];
              # Win default-device selection over the raw multichannel sink.
              "priority.session" = 2000;
            };
            "playback.props" = {
              "node.name" = "game_stereo.output";
              "audio.position" = [ "FL" "FR" ];
              "node.target" = "alsa_output.usb-Focusrite_Clarett__8Pre_00011584-00.multichannel-output";
              "stream.dont-remix" = true;
              "node.passive" = true;
            };
          };
        }
      ];
    };
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # users.users.alice = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     tree
  #   ];
  # };

  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  # environment.systemPackages = with pkgs; [
  #   vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #   wget
  # ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;


  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #

  # --- Scroll Lock LED follows mute state ----------------------------------
  # GNOME grabs Scroll Lock for the mute keybind, so the kernel no longer
  # toggles the lock LED itself, and the LED files are root-owned. Detach the
  # kernel's "kbd-scrolllock" trigger and let the `users` group write the
  # brightness file, so ~/.local/bin/discord-mute-toggle can mirror mic-mute
  # state onto every scroll-lock LED (Logitech + Apple keyboards).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="leds", KERNEL=="*::scrolllock", ATTR{trigger}="none", RUN+="${pkgs.coreutils}/bin/chgrp users /sys/class/leds/%k/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/leds/%k/brightness"
  '';
  # -------------------------------------------------------------------------
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}


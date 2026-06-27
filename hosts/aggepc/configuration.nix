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

  # The replay buffer records the mic from the "gsr_mic_boost" virtual source
  # (a +50% gain filter-chain fed by Easy Effects' processed "easyeffects_source"
  # — see the 99-gsr-mic-boost pipewire config). The boost node is created by
  # pipewire and only links once easyeffects_source exists, so it only carries
  # real audio after the easyeffects user service has registered that upstream.
  # At login the replay service can otherwise win the race and start before the
  # node is enumerable, silently dropping the mic track — so poll (up to ~30s)
  # until gsr can see the boost source first.
  #
  # On timeout we exit NON-ZERO so the unit's `Restart=on-failure` retries the
  # whole service rather than launching gpu-screen-recorder against a missing
  # `gsr_mic_boost` (which makes gsr exit immediately and crash-loop, leaving no
  # replay buffer for Alt+F10 to save). This recovers automatically if pipewire
  # is slow to load the 99-gsr-mic-boost filter-chain (e.g. it was started with
  # stale config and the node only appears after a later pipewire restart).
  gsrWaitForMic = pkgs.writeShellScript "gsr-wait-for-mic-boost" ''
    for _ in $(seq 1 60); do
      if ${pkgs.gpu-screen-recorder}/bin/gpu-screen-recorder --list-audio-devices \
           | ${pkgs.gnugrep}/bin/grep -q '^gsr_mic_boost|'; then
        exit 0
      fi
      sleep 0.5
    done
    echo "gsr-replay: gsr_mic_boost not found after timeout; failing so the unit retries" >&2
    exit 1
  '';

  # Heals an early-boot PipeWire race. At login the PipeWire daemon starts very
  # early (before the session is fully settled) and silently fails to load the
  # 99-gsr-mic-boost filter-chain module — the daemon keeps running fine but
  # `gsr_mic_boost` never appears, so every fresh boot loses the boosted mic and
  # gsr-replay has nothing to record/save. The failure isn't logged (the main
  # pipewire daemon is silent at the default log level), but it's perfectly
  # reproducible: restarting the audio stack *after* the session is up always
  # loads the module. So once everything is up, check for the node and, only if
  # it's missing, restart pipewire/wireplumber to force the module to (re)load.
  # This runs at login before any audio is in use, so the brief restart is
  # harmless; on boots where the daemon did load the filter-chain it's a no-op.
  gsrMicBoostHeal = pkgs.writeShellScript "gsr-mic-boost-heal" ''
    has_node() {
      ${pkgs.gpu-screen-recorder}/bin/gpu-screen-recorder --list-audio-devices \
        | ${pkgs.gnugrep}/bin/grep -q '^gsr_mic_boost|'
    }
    # Give the boot pipewire a brief chance to have loaded it already.
    for _ in $(seq 1 20); do
      has_node && exit 0
      sleep 0.5
    done
    echo "gsr-mic-boost: node missing; restarting pipewire/wireplumber to load the filter-chain" >&2
    ${pkgs.systemd}/bin/systemctl --user restart pipewire.service wireplumber.service
    for _ in $(seq 1 40); do
      has_node && exit 0
      sleep 0.5
    done
    echo "gsr-mic-boost: node still missing after pipewire restart" >&2
    exit 1
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
      settings = {
        "org/gnome/desktop/wm/preferences" = {
          button-layout = "appmenu:minimize,maximize,close";
        };

        # Alt+F10 → save the gsr-replay rolling buffer (last 5 minutes). The
        # command sends SIGUSR1 to the gpu-screen-recorder main process; see the
        # gsr-replay.service below for why --kill-whom=main is required. Declared
        # here (rather than only in the user's writable dconf) so the binding is
        # reproduced on a fresh install. The list is a profile default; the
        # user's writable dconf still wins, so any extra custom bindings added in
        # GNOME Settings (e.g. discord-mute) are preserved.
        "org/gnome/settings-daemon/plugins/media-keys" = {
          custom-keybindings = [
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/gsr-save/"
          ];
        };
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/gsr-save" = {
          name = "Save replay (last 5 min)";
          command = "systemctl --user kill --kill-whom=main -s SIGUSR1 gsr-replay.service";
          binding = "<Alt>F10";
        };
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
  # Save the last 5 minutes any time with (Alt+F10 is bound to this via the
  # GNOME custom keybinding declared in programs.dconf above):
  #   systemctl --user kill --kill-whom=main -s SIGUSR1 gsr-replay.service
  # NOTE: --kill-whom=main is required. Without it, systemd signals every
  # process in the unit's cgroup, so SIGUSR1 also hits the gsr-kms-server helper
  # child and breaks KMS capture ("failed to get kms ... no drm found"), after
  # which all saves silently produce nothing. The flag targets only the main
  # gpu-screen-recorder process, which is what interprets SIGUSR1 as "save".
  # Force the gsr_mic_boost filter-chain to load once the session is up, working
  # around the early-boot PipeWire race (see gsrMicBoostHeal above). gsr-replay
  # is ordered after this so the replay buffer never starts without the boosted
  # mic. Kept separate from gsr-replay so the (occasional) pipewire restart isn't
  # entangled with the recorder's own start/restart logic.
  systemd.user.services.gsr-mic-boost = {
    description = "Ensure the gsr_mic_boost filter-chain is loaded (heals early-boot pipewire race)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [
      "graphical-session.target"
      "pipewire.service"
      "wireplumber.service"
      "easyeffects.service"
    ];
    wants = [ "pipewire.service" "wireplumber.service" "easyeffects.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${gsrMicBoostHeal}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.user.services.gsr-replay = {
    description = "GPU Screen Recorder — rolling 5-minute replay buffer";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    # Start after easyeffects so its "easyeffects_source" mic node exists; the
    # gsrWaitForMic ExecStartPre below additionally waits for the node to be
    # registered (the service is "started" the moment the process forks, before
    # the PipeWire node is up).
    # Order after pipewire/wireplumber (which build the node graph and load the
    # 99-gsr-mic-boost filter-chain) AND easyeffects (whose easyeffects_source
    # the boost taps). Without the explicit pipewire/wireplumber ordering a
    # rebuild that restarts the audio stack can leave gsr-replay started against
    # a not-yet-loaded gsr_mic_boost node. Also order after gsr-mic-boost, which
    # guarantees the filter-chain is actually loaded (it heals the early-boot
    # pipewire race) before the recorder starts.
    after = [
      "graphical-session.target"
      "pipewire.service"
      "wireplumber.service"
      "easyeffects.service"
      "gsr-mic-boost.service"
    ];
    wants = [
      "pipewire.service"
      "wireplumber.service"
      "easyeffects.service"
      "gsr-mic-boost.service"
    ];
    serviceConfig = {
      ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p %h/Videos"
        "${gsrWaitForMic}"
      ];
      # The mic tracks use "easyeffects_source" (Easy Effects' processed virtual
      # source) instead of "default_input", so recordings get the noise-
      # suppressed mic. Track layout: Mixed (desktop+mic), Desktop, Microphone.
      ExecStart = "${pkgs.gpu-screen-recorder}/bin/gpu-screen-recorder -w DP-1 -c mkv -k hevc -f 60 -r 300 -restart-replay-on-save yes -a \"default_output|gsr_mic_boost\" -a default_output -a gsr_mic_boost -sc ${gsrSaveScript} -o %h/Videos/";
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
    # Order after BOTH pipewire and wireplumber: pipewire provides the sink, but
    # wireplumber is what actually builds the node graph. If EasyEffects starts
    # while the graph is still settling it can fail to link its sink monitor into
    # the first output plugin (easyeffects_sink:monitor -> ee_soe_*), leaving the
    # output chain headless and producing silence even though every node exists.
    after = [ "graphical-session.target" "pipewire.service" "wireplumber.service" ];
    wants = [ "pipewire.service" "wireplumber.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.easyeffects}/bin/easyeffects --gapplication-service";
      ExecStop = "${pkgs.easyeffects}/bin/easyeffects --quit";
      # PipeWire/WirePlumber may not be ready yet at login; retry until they are.
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

    # Recording-only mic boost. The screen recorder (gsr-replay) should capture
    # the mic ~50% louder than everyone else hears it, WITHOUT changing the level
    # other apps (Discord/Firefox) get from "easyeffects_source". So tap the
    # processed Easy Effects source through a filter-chain that applies a fixed
    # +50% amplitude gain (linear Mult = 1.5, ~+3.5 dB) and expose the result as
    # a separate virtual source "gsr_mic_boost" that ONLY gsr-replay records.
    # node.passive on the capture side keeps the filter idle until gsr actually
    # opens it, so it costs nothing when not recording.
    extraConfig.pipewire."99-gsr-mic-boost" = {
      "context.modules" = [
        {
          name = "libpipewire-module-filter-chain";
          args = {
            "node.description" = "GSR Mic Boost (+50%)";
            "media.name" = "GSR Mic Boost";
            "filter.graph" = {
              nodes = [
                { type = "builtin"; name = "gain_FL"; label = "linear"; control = { "Mult" = 1.5; "Add" = 0.0; }; }
                { type = "builtin"; name = "gain_FR"; label = "linear"; control = { "Mult" = 1.5; "Add" = 0.0; }; }
              ];
              inputs = [ "gain_FL:In" "gain_FR:In" ];
              outputs = [ "gain_FL:Out" "gain_FR:Out" ];
            };
            "audio.position" = [ "FL" "FR" ];
            "capture.props" = {
              "node.name" = "gsr_mic_boost.input";
              # Run only while gsr is recording this node.
              "node.passive" = true;
              # Always pull from the Easy Effects processed mic, never follow the
              # default source (`node.dont-reconnect` makes the pin sticky).
              "target.object" = "easyeffects_source";
              "node.dont-reconnect" = true;
              "stream.dont-remix" = true;
            };
            "playback.props" = {
              "node.name" = "gsr_mic_boost";
              "node.description" = "GSR Mic Boost (+50%)";
              "media.class" = "Audio/Source";
              "audio.position" = [ "FL" "FR" ];
              # Keep it out of normal app/default selection — only gsr records it.
              "priority.session" = 100;
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


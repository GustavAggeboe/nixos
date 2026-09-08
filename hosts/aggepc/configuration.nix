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
  # (a gain-boosted filter-chain fed by Easy Effects' processed "easyeffects_source"
  # — created by the gsr-mic-boost.service filter-chain process below). That
  # service starts only after easyeffects has registered easyeffects_source, so
  # the boost links its upstream cleanly. gsr-replay is ordered after it, but the
  # service being "started" only means the process forked — the PipeWire node can
  # take a moment more to enumerate — so also poll (up to ~30s) until gsr can see
  # the boost source before launching the recorder.
  #
  # On timeout we exit NON-ZERO so the unit's `Restart=on-failure` retries the
  # whole service rather than launching gpu-screen-recorder against a missing
  # `gsr_mic_boost` (which makes gsr exit immediately and crash-loop, leaving no
  # replay buffer for Alt+F10 to save).
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

  # Recording-only mic boost, run as its OWN PipeWire client process (see
  # gsr-mic-boost.service). The screen recorder should capture the mic louder
  # than everyone else hears it WITHOUT changing the level other apps
  # (Discord/Firefox) get from "easyeffects_source". So tap the processed Easy
  # Effects source through a filter-chain that applies a fixed linear amplitude
  # gain (the `Mult` control — 1.0 = unity, higher = louder) and expose the
  # result as a separate virtual source "gsr_mic_boost" that ONLY gsr-replay
  # records. `node.passive` on the capture side keeps the filter idle until gsr
  # actually opens it, so it costs nothing when not recording.
  #
  # Why a dedicated `pipewire -c` process instead of loading this filter-chain as
  # a `context.module` in the main daemon (services.pipewire.extraConfig): the
  # in-daemon module is created at daemon start, BEFORE easyeffects registers
  # easyeffects_source, so with the target pinned it silently fails to appear and
  # the boosted mic is missing on every boot. The old workaround restarted the
  # whole pipewire/wireplumber stack at login to force a reload — but that ripped
  # the PipeWire connection out from under the already-running easyeffects, which
  # core-dumped and came back with its output chain mis-routed, so speaker output
  # was silent until you manually reselected the sink. Running the filter-chain
  # as a separate client started AFTER easyeffects removes both problems: nothing
  # restarts the daemon, and easyeffects_source already exists so the boost links
  # first try.
  gsrMicBoostConf = pkgs.writeText "gsr-mic-boost.conf" ''
    context.properties = { log.level = 0 }
    context.spa-libs = {
      audio.convert.* = audioconvert/libspa-audioconvert
      support.*       = support/libspa-support
    }
    context.modules = [
      { name = libpipewire-module-rt args = { } flags = [ ifexists nofail ] }
      { name = libpipewire-module-protocol-native }
      { name = libpipewire-module-client-node }
      { name = libpipewire-module-adapter }
      { name = libpipewire-module-filter-chain
        args = {
          node.description = "GSR Mic Boost"
          media.name       = "GSR Mic Boost"
          filter.graph = {
            nodes = [
              { type = builtin name = gain_FL label = linear control = { Mult = 2.0 Add = 0.0 } }
              { type = builtin name = gain_FR label = linear control = { Mult = 2.0 Add = 0.0 } }
            ]
            inputs  = [ "gain_FL:In" "gain_FR:In" ]
            outputs = [ "gain_FL:Out" "gain_FR:Out" ]
          }
          audio.position = [ FL FR ]
          capture.props = {
            node.name         = gsr_mic_boost.input
            # Run only while gsr is recording this node.
            node.passive      = true
            # Always pull from the Easy Effects processed mic, never follow the
            # default source (`node.dont-reconnect` makes the pin sticky). This
            # process starts after easyeffects, so the target already exists.
            target.object     = easyeffects_source
            node.dont-reconnect = true
            stream.dont-remix = true
          }
          playback.props = {
            node.name        = gsr_mic_boost
            node.description = "GSR Mic Boost"
            media.class      = Audio/Source
            audio.position   = [ FL FR ]
            # Keep it out of normal app/default selection — only gsr records it.
            priority.session = 100
          }
        }
      }
    ]
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
    # Wait indefinitely at the menu for a manual selection instead of
    # counting down and auto-booting the default entry.
    timeout = null;
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
  i18n.defaultLocale = "en_GB.UTF-8";
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

  # Flatpak + Flathub. Needed for Sober (org.vinegarhq.Sober), the only
  # working way to run the Roblox player on Linux (runs the Android client;
  # the old Wine route is blocked by Roblox's Hyperion anti-cheat).
  services.flatpak.enable = true;
  systemd.services.flatpak-repo = {
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.flatpak ];
    script = ''
      flatpak remote-add --if-not-exists \
        flathub https://flathub.org/repo/flathub.flatpakrepo
    '';
  };

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
    google-chrome  # Google Chrome (unfree; allowUnfree is set in modules/nixos.nix)
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

    ffmpeg  # CLI audio/video transcoding and processing
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
  # The recording-only mic boost filter-chain (gsrMicBoostConf above), run as its
  # own PipeWire client process. Started AFTER easyeffects so its upstream
  # "easyeffects_source" already exists and the boost links first try — no daemon
  # restart, no race. `bindsTo` easyeffects so if the effects daemon restarts,
  # this re-runs and re-pins to the fresh easyeffects_source. gsr-replay is
  # ordered after this so the replay buffer never starts without the boosted mic.
  systemd.user.services.gsr-mic-boost = {
    description = "GSR Mic Boost — recording-only gain filter-chain (PipeWire client)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    bindsTo = [ "easyeffects.service" ];
    after = [
      "graphical-session.target"
      "pipewire.service"
      "wireplumber.service"
      "easyeffects.service"
    ];
    wants = [ "pipewire.service" "wireplumber.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.pipewire}/bin/pipewire -c ${gsrMicBoostConf}";
      # PipeWire/easyeffects may still be settling at login; retry until the
      # upstream source is there to link.
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
    # Order after pipewire/wireplumber (which build the node graph) AND
    # gsr-mic-boost (the filter-chain client that creates the gsr_mic_boost
    # source this recorder captures). Without the explicit pipewire/wireplumber
    # ordering a rebuild that restarts the audio stack can leave gsr-replay
    # started against a not-yet-loaded gsr_mic_boost node.
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

  # Autostart RustDesk's background service on login so the machine accepts
  # incoming remote-desktop connections without anyone opening the app. RustDesk
  # is normally driven by a privileged `--service` worker that does the screen
  # capture, input injection and connection handling; the GUI/tray only talks to
  # it over IPC and shows your ID/password. Run it as a *user* service inside the
  # graphical session (not a root system service) so it can reach this Wayland
  # session's screencast portal and PipeWire — a root daemon can't capture a
  # Wayland session.
  #
  # NOTE: this makes RustDesk *running and reachable* after login; to connect
  # without anyone clicking "Accept" at the machine you still have to set a
  # permanent password once: open RustDesk → Settings → Security → set a
  # permanent password (and note the ID shown in the main window). On Wayland the
  # very first incoming connection also pops the GNOME screen-share approval; once
  # approved RustDesk stores a restore token and later connections are silent.
  systemd.user.services.rustdesk = {
    description = "RustDesk — remote desktop service (unattended access)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" "wireplumber.service" ];
    wants = [ "pipewire.service" "wireplumber.service" ];
    serviceConfig = {
      ExecStart = "${rustdesk-wayland}/bin/rustdesk --service";
      # Portal/PipeWire may not be ready the instant the session starts; retry.
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
    # The recording-only mic boost is NOT loaded here as an in-daemon
    # context.module — it races the daemon start (before easyeffects_source
    # exists) and silently fails to appear. It runs instead as its own PipeWire
    # client process started after easyeffects: see gsrMicBoostConf and
    # systemd.user.services.gsr-mic-boost above.

    # Keep the Focusrite Clarett+ 8Pre as the default CAPTURE device.
    # EasyEffects follows the default source (verified: setting the default to
    # the Clarett makes EE's input chain re-link to it immediately), so if the
    # Clarett isn't the highest-priority source at login, EE grabs whatever is —
    # in practice the Webcam C270's mono mic — and the real mic goes dead until
    # the source is switched by hand. Nothing pinned the Clarett after the old
    # `99-clarett-stereo` rule was removed with game_stereo, so give its input a
    # high priority.session (default source = highest priority) and demote the
    # webcam mic so it can never win the default again.
    wireplumber.extraConfig."51-clarett-default-input" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            { "node.name" = "alsa_input.usb-Focusrite_Clarett__8Pre_00011584-00.multichannel-input"; }
          ];
          actions.update-props = {
            "priority.session" = 2000;
            "node.description" = "Clarett+ 8Pre";
          };
        }
        {
          # Webcam mic: last-resort only, never the auto-selected default.
          matches = [
            { "node.name" = "alsa_input.usb-046d_0825_C2C53110-02.mono-fallback"; }
          ];
          actions.update-props."priority.session" = 0;
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


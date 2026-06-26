# Windows-style mouse acceleration via maccel (https://github.com/Gnarus-G/maccel).
#
# maccel is a kernel module that applies a RawAccel-style acceleration curve to
# raw mouse input *before* it reaches the display server, so it works the same on
# Wayland (GNOME/Mutter here) and X11 — unlike libinput's "custom" profile, which
# GNOME does not expose. This is the only way to get a configurable, Windows-like
# acceleration curve inside a stock GNOME Wayland session.
#
# NOTE: maccel reproduces RawAccel's *parametric* curves (linear/natural/
# synchronous), which approximate the Windows "Enhance pointer precision" feel —
# they are not a bit-exact clone of Microsoft's EPP sigmoid. Tune live with the
# TUI (`maccel tui`, shows a sensitivity graph); CLI/TUI changes are temporary,
# so once a curve feels right, copy the values into `parameters` below and
# `nixos-rebuild switch` to persist them.
{
  inputs,
  config,
  lib,
  ...
}:
{
  imports = [ inputs.maccel.nixosModules.default ];

  hardware.maccel = {
    enable = true;
    enableCli = true; # installs `maccel` (CLI + `maccel tui`) for live tuning

    # Starting point — a gentle linear curve. Open `maccel tui` and adjust until
    # it matches the Windows feel, then write the final numbers here.
    parameters = {
      mode = "linear";

      # IMPORTANT: set this to your mouse's actual hardware DPI. maccel uses it to
      # normalise input speed so the curve is independent of DPI. Wrong DPI here
      # just means the curve's "knee" sits at the wrong hand speed.
      inputDpi = 1000.0;

      sensMultiplier = 1.0; # overall sensitivity floor (1.0 = unchanged when slow)
      acceleration = 0.05; # how hard sensitivity ramps with speed (higher = more)
      offset = 2.0; # input speed (counts/ms) below which no accel is applied
      outputCap = 2.0; # ceiling on the sensitivity multiplier at high speed
    };
  };

  # maccel is now the sole source of pointer acceleration. Stop GNOME/libinput
  # from also applying its built-in "adaptive" curve on top (which would stack two
  # accelerations). "flat" = libinput passes motion through 1:1; maccel shapes it.
  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/peripherals/mouse".accel-profile = "flat";
    }
  ];

  # Let normal users read/write the maccel parameters (so `maccel`/`maccel tui`
  # work without sudo). The maccel module creates the group; we populate it.
  users.groups.maccel.members = lib.attrNames (
    lib.filterAttrs (_: u: u.isNormalUser) config.users.users
  );
}

{ ... }:

# Fix for: GNOME logs you straight back out to GDM, at random, with the machine
# still running (no shutdown, no reboot — mutter dies and takes the Wayland
# session with it).
#
# gnome-shell was SIGSEGV'ing inside libgbm with an identical backtrace every
# time (verified across four coredumps, 2026-06-29 .. 2026-09-17):
#
#   #0 gbm_bo_destroy            (libgbm.so.1)
#   #1 get_back_bo               (libEGL_mesa.so.0)
#   #2 dri2_drm_image_get_buffers
#   ... -> eglMakeCurrent -> cogl_onscreen_egl_bind -> maybe_post_next_frame
#
# The kernel logged `segfault at 28` and gbm_bo_destroy() starts with
# `mov 0x28(%rdi),%rax` with no NULL check, i.e. the argument was NULL: Mesa
# called gbm_bo_destroy(NULL).
#
# The caller is destroy_oldest_unused_bo() in src/egl/drivers/dri2/platform_drm.c.
# It walks the surface's colour buffers for the oldest unused one, but never
# checks whether the buffer it picks actually HAS a bo — and a colour buffer's
# ->bo is legitimately NULL (never allocated, or zeroed by a previous call to
# this same function). Introduced upstream in dd7ae4109189 ("egl/gbm: Destroy
# excess BOs"), fixed in 962fd789c82a ("egl/gbm: Ignore buffers with no BO for
# destroying excess BOs"), which landed AFTER the 26.1.2 that nixpkgs ships.
#
# Why this box gets hit and most don't: the path only runs after 1000 consecutive
# frames (~16s at 60fps) in which the unlocked colour buffers have differing
# ages, which needs buffers to sit locked for long stretches — and aggepc keeps
# gpu-screen-recorder's replay buffer pinned to the screen 24/7, holding exactly
# those references. Hence "random" logouts hours apart rather than never.
#
# Dropped once nixpkgs' mesa contains 962fd789c82a (26.1.3+ / 26.2) — at which
# point this patch will fail to apply and the build will tell you loudly.
{
  nixpkgs.overlays = [
    (_final: prev: {
      mesa = prev.mesa.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/mesa-egl-gbm-null-bo.patch ];
      });
    })
  ];
}

{ pkgs, ... }:

{
  # Generally useful packages.
  environment.systemPackages = with pkgs; [
    # Common utilities.
    file
    ripgrep
    binutils
    pciutils
    usbutils

    # Zipping.
    zip
    unzip

    # Etc.
    keyd
    wget
    curl
    speedtest-cli
  ];
}

# Home of my configuration files

This is where I keep all of my important personal configurations, including my
dotfiles, Nix packages, and NixOS configurations. These things are organized
into their own subdirectories, to have some sort of structure, which haven't put
too much thought into.


## Features

### Nix Cache

My favourite thing I've got going on is my Nix cache. My build server builds
all of my systems once a day, and each system tries pulling updates from this
repo once an hour.

I no longer worry about long rebuilds from overrides, as this whole system
is automated and I don't spend any time doing long rebuilds on my different
machines.


## Installation

To install an existing, non-flake `/etc/nixos` configuration into the structure
of this flake, one can run:

```sh
nix run github:swagtop/nixos#install --extra-experimental-features 'nix-command flakes'
```

This script exists mostly for my own usage, to quickly enroll any new computers
or virtual machines into my setup.

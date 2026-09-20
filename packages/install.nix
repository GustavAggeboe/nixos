{
  writeShellApplication,
  coreutils,
  git,
}:
writeShellApplication {
  name = "install-system";
  runtimeInputs = [
    coreutils
    git
  ];
  bashOptions = [ ];
  text = ''
    echo "Warning! This script will clone 'github:swagtop/nixos' into your /etc/nixos directory."
    echo "First it will move your current '/etc/nixos' directory into a temp directory, then it will move it back into the newly cloned '/etc/nixos/hosts/\$REPLY' directory."
    echo "Please enter the name of that which will become the \$REPLY variable."
    echo "(Or input Ctrl+c to cancel this script.)"

    read -r

    if [[ "$REPLY" == "" ]]; then
      echo "No name input, aborting script."
      exit 1
    fi

    echo

    TMP_DIR_NEW_NIXOS=$(mktemp -d)
    if ! git clone https://github.com/swagtop/nixos "$TMP_DIR_NEW_NIXOS"; then
      echo "Failed cloning 'github:swagtop/nixos' into a temp directory."
      echo "Aborting script, no changes have been made."
      exit 1
    fi

    echo

    if [ -d "$TMP_DIR_NEW_NIXOS/hosts/$REPLY" ]; then
      echo "Host '$REPLY' already exists in repo, choose another name."
      echo "Aborting script, no changes have been made."
      exit 1
    fi

    TMP_DIR_OLD_NIXOS=$(mktemp -d)
    if ! sudo cp -r /etc/nixos/* "$TMP_DIR_OLD_NIXOS"; then
      echo "Failed copying existing '/etc/nixos' to a temp directory."
      echo "Aborting script, no changes have been made."
      exit 1
    fi

    echo

    step=0
    function abort-on-failure {
      ((step+=1))
      if ! "$@"; then
        echo
        echo "Step $step: '$*' failed."
        echo "Aborting script, and restoring original '/etc/nixos'."

        sudo rm -rf /etc/nixos
        sudo mv "$TMP_DIR_OLD_NIXOS" /etc/nixos

        exit 1
      fi
    }

    abort-on-failure sudo rm -rf /etc/nixos/*
    abort-on-failure sudo mv "$TMP_DIR_NEW_NIXOS"/* "$TMP_DIR_NEW_NIXOS"/.* /etc/nixos
    abort-on-failure sudo mkdir "/etc/nixos/hosts/$REPLY"
    abort-on-failure sudo cp -r "$TMP_DIR_OLD_NIXOS"/* "/etc/nixos/hosts/$REPLY"
    abort-on-failure cd /etc/nixos; sudo git add .; sudo chown -R root .;

    echo

    echo "Succcessfully installed flake on system."
    echo "Add your host to the flake by importing your 'configuration.nix' in 'flake.nix'."
    echo "If you have forked the repository on GitHub, set your own repo as upstream with:"
    echo "'git remote set-url origin https://github.com/<username>/nixos'"
  '';
}

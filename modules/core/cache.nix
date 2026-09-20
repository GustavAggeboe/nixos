{
  config,
  pkgs,
  lib,
  patches,
  ...
}:
let
  cfg = config.swag.cache;

  # Setting services to be nicer, for less disruptive background updates.
  # https://positron.solutions/articles/building-nicely-with-rust-and-nix
  niceService = {
    Nice = 18;
    IOSchedulingClass = "idle";
    IOSchedulingPriority = 7;
  };
in
{
  options = {
    swag.cache = {
      enable = lib.mkEnableOption "Opt into the swag cache system.";

      mode = lib.mkOption {
        type = lib.types.enum [
          "user"
          "host"
        ];
        default = "user";
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "https://cache.spirre.vip/";
      };

      cacheLogFile = lib.mkOption {
        type = lib.types.externalPath;
        default = "/srv/f/cache-log.txt";
      };

      flakeDir = lib.mkOption {
        type = lib.types.externalPath;
        default = "/etc/nixos";
      };

      # The publickey generated here was made like so:
      # 'mkdir -p /var/lib/secrets'
      # 'nix-store --generate-binary-cache-key cache.spirre.vip-1 /var/lib/secrets/harmonia.secret /var/lib/secrets/harmonia.pub'
      # ... where the 'harmonia.pub' file contains the 'default' value below.
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "cache.spirre.vip-1:i4kVSThuBka1m8B5WAE/97qLDAydBE9RlKOh4zNmLRc=";
      };

      # The private key file here is generated together with the public key in
      # the command above.
      secretKeyFile = lib.mkOption {
        type = lib.types.externalPath;
        default = "/var/lib/secrets/harmonia.secret";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [
        pkgs.git
        pkgs.gh
      ];
    })

    (lib.mkIf (cfg.enable && cfg.mode == "user") {
      nix.settings = {
        substituters = lib.mkBefore [ cfg.url ];
        trusted-public-keys = lib.mkBefore [ cfg.publicKey ];
      };

      nix.extraOptions = ''
        fallback = true
      '';

      systemd.services.user-nixos-cache-update = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        path = [
          pkgs.git
          pkgs.nix
          pkgs.nixos-rebuild
        ];

        serviceConfig = niceService // {
          Type = "oneshot";
          User = "root";
          WorkingDirectory = cfg.flakeDir;

          ExecStart = pkgs.writeShellScript "pull-system-flake" ''
            git fetch
            GIT_STATUS_RESULT=$(git status)

            if [[ "$GIT_STATUS_RESULT" =~ "Your branch is up to date" ]] || \
               [[ "$GIT_STATUS_RESULT" =~ "Your branch is ahead of" ]]
            then
              echo "System is up to date."
            else
              # Rebase new changes and autostash to avoid any merge conflicts.
              git rebase --autostash

              # Stop existing rebuild if in progressm.
              systemctl stop nixos-rebuild-switch-to-configuration

              # Rebuild with new inputs.
              nixos-rebuild switch --flake ${cfg.flakeDir}

              # Fetch new nixpkgs tarball from registry.
              nix run nixpkgs#hello -- -g ""
            fi
          '';
        };
      };

      systemd.timers.user-nixos-cache-update = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnUnitActiveSec = "1h";
          RandomizedDelaySec = "180";
          Persistent = true;
          OnCalendar = "daily";
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.mode == "host") {
      networking.firewall.allowedTCPPorts = [ 5000 ];
      services.harmonia = {
        cache = {
          enable = true;
          signKeyPaths = [ cfg.secretKeyFile ];
          settings = {
            priority = 20;
            extra_logfile_path = cfg.cacheLogFile;
          };
        };
        package = pkgs.harmonia.overrideAttrs (oldAttrs: {
          patches = oldAttrs.patches or [ ] ++ [ patches.harmonia-extra-logfile ];
        });
      };

      systemd.services.host-nixos-cache-update =
        let
          update-script = pkgs.writeShellApplication {
            name = "update-system-flake";
            runtimeInputs = with pkgs; [
              coreutils
              gawk
              git
              nix
              nixos-rebuild
              systemd
            ];
            bashOptions = [ ];
            text = ''
              printf "" > "${cfg.cacheLogFile}" # Clear log at beginning of service.

              function print-with-underline {
                case "$2" in
                  --time) string="$(date '+%H:%M') $1";;
                  --date-time) string="$(date '+%Y-%m-%d @ %H:%M') $1";;
                  *) string="$1"
                esac

                echo "$string"
                # shellcheck disable=SC2046
                printf '%0.s=' $(eval echo "{1..''${#string}}")
                echo
              }

              # https://discourse.nixos.org/t/ssl-cert-file-and-connection-issues-in-nix-shells/7856
              export SSL_CERT_FILE="/etc/ssl/certs/ca-bundle.crt"

              print-with-underline "Beginning update" --date-time
              # Making sure this service can run, by stopping any lingering rebuilds.
              systemctl stop nixos-rebuild-switch-to-configuration.service 2>&1 /dev/null
              echo

              print-with-underline "Pulling repository" --time
              git fetch
              git rebase --autostash || echo 'Failed git rebase!'
              echo

              FLAKE_INPUTS_UPDATE_DATE=$(date '+%Y-%m-%d') 
              print-with-underline "Updating flake inputs" --time
              nix flake update --flake . 2>&1
              echo

              declare -a allSystems=()

              systemCount=$(
                nix eval .#nixosConfigurations \
                  --apply 'i: builtins.length (builtins.attrNames i)'
              )

              # Doing all of this to allow for whitespace in hostnames.
              for i in $(eval echo "{0..$((systemCount - 1))}"); do
                hostname=$(
                  nix eval --raw .#nixosConfigurations --apply \
                    "i: builtins.elemAt (builtins.attrNames i) $i"
                )
                allSystems+=("$hostname")
              done

              declare -a buildSystems=()
              declare -a ignoreSystems=()

              for system in "''${allSystems[@]}"; do
                cacheEnabled=$(nix eval .#nixosConfigurations."$system".config.swag.cache.enable)
                if [[ $cacheEnabled == "true" ]]; then
                  buildSystems+=("$system")
                else
                  ignoreSystems+=("$system")
                fi
              done

              echo
              print-with-underline "Building the following hosts"
              printf "%s\n" "''${buildSystems[@]}"
              echo

              if [[ ''${#ignoreSystems[@]} != 0 ]]; then
                print-with-underline "Ignoring the following hosts"
                printf "%s\n" "''${ignoreSystems[@]}"
                echo
              fi

              for system in "''${buildSystems[@]}"; do
                # Skip building system if it is not using the cache.
                print-with-underline "Building '$system'" --time
                nixos-rebuild build --flake .#"$system" --no-link -j 1
                echo
              done

              print-with-underline "Rebuilding and switching" --time
              nixos-rebuild switch --flake .
              echo

              print-with-underline "Committing lockfile and pushing" --time
              GIT_COMMIT_RESULT=$(git commit -m "$FLAKE_INPUTS_UPDATE_DATE Automatic lockfile update." flake.lock)
              if [[ ! $GIT_COMMIT_RESULT =~ "nothing to commit" ]]; then
                echo "Pushing to main."
                git push
              else
                echo "No changes have been made, not pushing."
              fi
              echo

              print-with-underline "Finished update" --date-time
            '';
          };
        in
        {
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          path = [ pkgs.gh ];

          environment = {
            NO_COLOR = "1";
          };

          restartIfChanged = false;

          serviceConfig = niceService // {
            Type = "oneshot";
            User = "root";
            WorkingDirectory = cfg.flakeDir;
            ExecStart = lib.getExe update-script;

            StandardOutput = "file:${cfg.cacheLogFile}";
            # StandardError = "file:${cfg.cacheLogFile}";
          };
        };

      systemd.timers.host-nixos-cache-update = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          RandomizedOffsetSec = "30m";
          OnCalendar = "02:00";
        };
      };
    })
  ];
}

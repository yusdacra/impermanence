{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.home.persistence;

  persistentStoragePaths = attrNames cfg;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths sanitizeName;
in
{
  options = {

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule {
          options =
            {
              directories = mkOption {
                type = with types; listOf str;
                default = [ ];
              };

              files = mkOption {
                type = with types; listOf str;
                default = [ ];
              };

              removePrefixDirectory = mkOption {
                type = types.bool;
                default = false;
              };
            };
        }
      );
    };

  };

  config = {
    home.file =
      let
        link = file:
          pkgs.runCommand
            "${sanitizeName file}"
            { }
            "ln -s '${file}' $out";

        mkLinkNameValuePair = persistentStoragePath: file: {
          name =
            if cfg.${persistentStoragePath}.removePrefixDirectory then
              dirListToPath (tail (splitPath [ file ]))
            else
              file;
          value = { source = link (concatPaths [ persistentStoragePath file ]); };
        };

        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs (map
            (mkLinkNameValuePair persistentStoragePath)
            (cfg.${persistentStoragePath}.files)
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    systemd.user.services =
      let
        mkBindMountService = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = concatPaths [ persistentStoragePath dir ];
            mountPoint = concatPaths [ config.home.homeDirectory mountDir ];
            name = "bindMount-${sanitizeName targetDir}";
            startScript = pkgs.writeShellScript name ''
              set -eu
              if ! ${pkgs.utillinux}/bin/mount | grep "${mountPoint}"; then
                  ${pkgs.bindfs}/bin/bindfs -f --no-allow-other "${targetDir}" "${mountPoint}"
              else
                  echo "There is already an active mount at or below ${mountPoint}!" >&2
                  exit 1
              fi
            '';
            stopScript = pkgs.writeShellScript "unmount-${name}" ''
              fusermount -uz "${mountPoint}"
            '';
          in
          {
            inherit name;
            value = {
              Unit = {
                Description = "Bind mount ${targetDir} at ${mountPoint}";
                PartOf = [ "graphical-session-pre.target" ];

                # Don't restart the unit, it could corrupt data and
                # crash programs currently reading from the mount.
                X-RestartIfChanged = false;
              };

              Install.WantedBy = [ "default.target" ];

              Service = {
                ExecStart = "${startScript}";
                ExecStop = "${stopScript}";
              };
            };
          };

        mkBindMountServicesForPath = persistentStoragePath:
          listToAttrs (map
            (mkBindMountService persistentStoragePath)
            cfg.${persistentStoragePath}.directories
          );
      in
      builtins.foldl'
        recursiveUpdate
        { }
        (map mkBindMountServicesForPath persistentStoragePaths);

    home.activation =
      let
        dag = config.lib.dag;

        mkBindMount = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = concatPaths [ persistentStoragePath dir ];
            mountPoint = concatPaths [ config.home.homeDirectory mountDir ];
            systemctl = "XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/$(id -u)} ${config.systemd.user.systemctlPath}";
          in
          ''
            if [[ ! -e "${targetDir}" ]]; then
                mkdir -p "${targetDir}"
            fi
            if [[ ! -e "${mountPoint}" ]]; then
                mkdir -p "${mountPoint}"
            fi
            if ${pkgs.utillinux}/bin/mount | grep "${mountPoint}"; then
                if ${pkgs.utillinux}/bin/mount | grep "${mountPoint}" | grep "${targetDir}"; then
                    mountedPaths["${mountPoint}"]=0
                else
                    # The target directory changed, so we need to remount
                    echo "remounting ${mountPoint}"
                    ${systemctl} --user stop bindMount-${sanitizeName targetDir}
                    ${pkgs.bindfs}/bin/bindfs --no-allow-other "${targetDir}" "${mountPoint}"
                    mountedPaths["${mountPoint}"]=1
                fi
            else
                ${pkgs.bindfs}/bin/bindfs --no-allow-other "${targetDir}" "${mountPoint}"
                mountedPaths["${mountPoint}"]=1
            fi
          '';

        mkBindMountsForPath = persistentStoragePath:
          concatMapStrings
            (mkBindMount persistentStoragePath)
            cfg.${persistentStoragePath}.directories;

        bindMountScript = {
          name = "createAndMountPersistentStoragePaths";
          value =
            dag.entryAfter
              [ "writeBoundary" ]
              ''
                declare -A mountedPaths
                ${(concatMapStrings mkBindMountsForPath persistentStoragePaths)}
              '';
        };

        mkUnmount = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = concatPaths [ config.home.homeDirectory mountDir ];
          in
          ''
            if [[ ''${mountedPaths["${mountPoint}"]} == 1 ]]; then
                fusermount -u "${mountPoint}"
            fi
          '';

        mkUnmountsForPath = persistentStoragePath:
          concatMapStrings
            (mkUnmount persistentStoragePath)
            cfg.${persistentStoragePath}.directories;

        unmountScript = {
          name = "unmountPersistentStoragePaths";
          value =
            dag.entryBefore
              [ "reloadSystemD" ]
              ''
                ${concatMapStrings mkUnmountsForPath persistentStoragePaths}
              '';
        };

      in
      listToAttrs [
        bindMountScript
        unmountScript
      ];
  };

}

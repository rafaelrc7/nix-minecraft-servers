{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    attrValues
    concatStringsSep
    filterAttrs
    getExe
    isDerivation
    makeLibraryPath
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    optional
    optionals
    optionalString
    types
    unique
    ;

  cfg = config.services.nix-minecraft-servers;

  runDir = "/run/nix-minecraft-servers";

  enabledServers = filterAttrs (_: server: server.enable) cfg.servers;
  backupServers = filterAttrs (_: server: server.backup.enable) enabledServers;

  eulaFile = pkgs.writeText "minecraft-eula-agreement.txt" ''
    # By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA).
    # Managed by NixOS
    eula=true
  '';

  mkRunServerJar =
    javaPackage:
    pkgs.writeShellScript "minecraft-server-run-jar" ''
      if [ -z "$1" ]; then
          echo "Server JAR was not supplied"
          exit 1
      fi

      ${optionalString pkgs.stdenvNoCC.hostPlatform.isLinux "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:${makeLibraryPath [ pkgs.udev ]}"}

      exec ${getExe javaPackage} -server ''${@:2} -jar "''${1}" nogui
    '';

  stopServer = pkgs.writeShellScript "minecraft-server-stop" ''
    if [ -z "$1" ]; then
        echo "Server name was not supplied"
        exit 1
    fi

    echo stop > "${runDir}/$1.stdin"
  '';

  serverModule = types.submodule (
    { name, ... }: {
      options = {
        enable = mkEnableOption "Minecraft server ${name}";

        eula = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether you've read and accepted the [Mojang Minecraft EULA](https://aka.ms/MinecraftEULA).
            This option must be set to `true` to run Minecraft server, or the file must be created manually.
          '';
        };

        autoStart = mkOption {
          type = types.bool;
          default = true;
          description = "Autostart server when computer starts.";
        };

        server = mkOption {
          type = types.nullOr (types.either types.package (types.either types.path types.str));
          default = null;
          description = "Path to a server jar or package that provides one. Can also be set to null to use jar in server directory.";
        };

        directory = mkOption {
          type = types.path;
          default = "${cfg.dataDir}/${name}";
          description = "Server working directory.";
        };

        javaPackage = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = "Java package to run this particular minecraft server instance, if `server` is either `null` or a jar file. If `null`, uses `services.nix-minecraft-servers.javaPackage`.";
        };

        jvmOpts = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Flags passed to the JVM running the server. Setting to `null` means it will use (and inherit) the value set in the environment through $JVM_OPTS.";
        };

        memory = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Allocated RAM for server. Setting to `null` means it will use (and inherit) the value set in the environment through $MEM.";
        };

        environmentFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a env file that can be used to override the default environment. If left null, it will use a `.env` file in the working directory if it exists.";
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
        };

        port = mkOption {
          type = types.port;
          default = 25565;
          description = "Currently this value will NOT be applied to the server, and will be used only by the `openFirewall` option";
        };

        backup = {
          enable = mkEnableOption "server backups";

          onCalendar = mkOption {
            type = types.str;
            default = "weekly";
          };

          path = mkOption {
            type = types.path;
            default = "${cfg.dataDir}/backups/${name}";
          };
        };
      };
    }
  );

  mkServiceOverride =
    name: serverCfg:
    let
      javaPackage = if serverCfg.javaPackage != null then serverCfg.javaPackage else cfg.javaPackage;
      runServerJar = mkRunServerJar javaPackage;
      memory = if serverCfg.memory != null then serverCfg.memory else "\${MEM}";
      jvmOpts =
        if serverCfg.jvmOpts != null then concatStringsSep " " serverCfg.jvmOpts else "\${JVM_OPTS}";
      serverJar =
        if builtins.typeOf serverCfg.server == "string" || builtins.typeOf serverCfg.server == "path" then
          toString serverCfg.server
        else
          null;
      execStart =
        if serverJar != null then
          ''${runServerJar} "${serverJar}" -Xms${memory} -Xmx${memory} ${jvmOpts}''
        else
          (
            if isDerivation serverCfg.server then
              "${getExe serverCfg.server} -server -Xms${memory} -Xmx${memory} ${jvmOpts}"
            else
              null
          );
    in
    nameValuePair "minecraft-server@${name}" {
      overrideStrategy = "asDropin";

      wantedBy = optional serverCfg.autoStart "multi-user.target";

      unitConfig.ConditionPathExists = serverCfg.directory;

      serviceConfig = {
        ExecStart = optionals (execStart != null) [
          ""
          execStart
        ];

        ExecStartPre = optional serverCfg.eula /* sh */ ''
          ${pkgs.coreutils}/bin/ln -sf "${eulaFile}" "${serverCfg.directory}/eula.txt"
        '';

        WorkingDirectory = serverCfg.directory;

        EnvironmentFile = optionals (serverCfg.environmentFile != null) [
          ""
          "-${toString serverCfg.environmentFile}"
        ];
        Environment =
          (optional (serverJar != null) "JAR_NAME=${serverJar}")
          ++ (optional (serverCfg.jvmOpts != null) "JVM_OPTS=${jvmOpts}")
          ++ (optional (serverCfg.memory != null) "MEM=${memory}");

        ReadWritePaths = [
          ""
          "${runDir}/${name}.stdin"
          serverCfg.directory
        ];
      };
    };

  mkBackupServiceOverride =
    name: serverCfg:
    nameValuePair "minecraft-server-backup@${name}" {
      overrideStrategy = "asDropin";

      unitConfig.ConditionDirectoryNotEmpty = serverCfg.directory;

      serviceConfig = {
        WorkingDirectory = serverCfg.directory;

        EnvironmentFile = optionals (serverCfg.environmentFile != null) [
          ""
          "-${toString serverCfg.environmentFile}"
        ];
        Environment = [
          "BACKUP_PATH=${serverCfg.backup.path}"
          "SERVER_DIR=${serverCfg.directory}"
        ];

        ReadWritePaths = [
          ""
          "${cfg.dataDir}/backups"
          serverCfg.directory
          serverCfg.backup.path
          "-${runDir}/${name}.stdin"
        ];
      };
    };

  mkBackupTimerOverride =
    name: serverCfg:
    nameValuePair "minecraft-server-backup@${name}" {
      overrideStrategy = "asDropin";

      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = [
        ""
        serverCfg.backup.onCalendar
      ];
    };
in
{
  options.services.nix-minecraft-servers = {
    enable = mkEnableOption "Enable minecraft servers setup";

    sudoRules = mkOption {
      type = types.bool;
      default = false;
      description = "Add sudo rules so that members of the set minecraft server's user group can run related systemctl commands without sudo";
    };

    user = mkOption {
      type = types.str;
      default = "minecraft";
      description = "Minecraft server services' system user's and group's name";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/srv/minecraft";
      description = "Minecraft server services' home directory";
    };

    javaPackage = mkOption {
      type = types.package;
      default = pkgs.jdk25_headless; # Minimum necessary version for minecraft 26.1 and newer
      defaultText = "pkgs.jdk25_headless";
      description = "Default Java package used to run jar-based Minecraft servers. Particular instances can set a specific java package if necessary.";
    };

    jvmOpts = mkOption {
      type = types.listOf types.str;
      default = [
        "-Djava.net.preferIPv6Addresses=true"
        "-XX:+UseZGC"
        "-XX:+UseCompactObjectHeaders"
      ];
      description = "Default JVM flags used to run servers. The default values are valid for the latest JVM versions, but may be incompatible with older ones. Particular instances can set specific values if necessary.";
    };

    memory = mkOption {
      type = types.str;
      default = "6G";
      description = "Default allocated RAM for servers. Particular instances can set specific values if necessary.";
    };

    servers = mkOption {
      type = types.attrsOf serverModule;
      default = { };
      description = "Definition of minecraft servers";
    };
  };

  config = mkIf cfg.enable {

    # User/Group
    users.users.${cfg.user} = {
      description = "Minecraft server service user";
      home = cfg.dataDir;
      createHome = true;
      isSystemUser = true;
      group = cfg.user;
      shell = "${pkgs.shadow}/bin/nologin";
    };
    users.groups.${cfg.user} = { };

    # Firewall Ports
    networking.firewall.allowedTCPPorts = unique (
      map (server: server.port) (attrValues (filterAttrs (_: server: server.openFirewall) enabledServers))
    );

    # Create servers' base directories
    systemd.tmpfiles.rules = [
      "d ${runDir}      0750 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.user} -"
    ]
    ++ (mapAttrsToList (
      name: serverCfg: "d ${serverCfg.directory}   0750 ${cfg.user} ${cfg.user} -"
    ) enabledServers)
    ++ (mapAttrsToList (
      name: serverCfg: "d ${serverCfg.backup.path} 0750 ${cfg.user} ${cfg.user} -"
    ) backupServers);

    systemd.services =
      (mapAttrs' mkServiceOverride enabledServers)
      // (mapAttrs' mkBackupServiceOverride backupServers)
      // {
        "minecraft-server@" = {
          unitConfig = {
            Description = "Minecraft Server - %i";
            Requires = "minecraft-server@%i.socket";
            After = [
              "network.target"
              "minecraft-server@%i.socket"
            ];
            ConditionPathExists = "${cfg.dataDir}/%i";
          };

          serviceConfig = {
            ExecStart = "${mkRunServerJar cfg.javaPackage} \"\${JAR_NAME}\" -Xms\${MEM} -Xmx\${MEM} \${JVM_OPTS}";
            ExecStop = ''${stopServer} "%i"'';
            Restart = "on-failure";
            RestartSec = "60s";

            WorkingDirectory = "${cfg.dataDir}/%i";

            User = cfg.user;
            Group = cfg.user;

            Sockets = "minecraft-server@%i.socket";
            StandardInput = "socket";
            StandardOutput = "journal";
            StandardError = "journal";

            # Set default variables
            Environment = [
              "JAR_NAME=server.jar"
              "MEM=${cfg.memory}"
              ''"JVM_OPTS=${concatStringsSep " " cfg.jvmOpts}"''
            ];

            # Override default variable values in environment file
            EnvironmentFile = "-${cfg.dataDir}/%i/.env";

            # this is necessary to keep systemd from killing the process before it exits after ExecStop is called
            KillSignal = "SIGCONT";

            # Hardening
            CapabilityBoundingSet = [ "" ];
            DeviceAllow = [ "" ];
            PrivateDevices = true;
            LockPersonality = true;
            PrivateTmp = true;
            PrivateUsers = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            UMask = "0077";
            ProtectSystem = "strict";
            ReadWritePaths = [
              "${runDir}/%i.stdin"
              "${cfg.dataDir}/%i"
            ];
            NoNewPrivileges = true;
            RemoveIPC = true;
          };
        };

        "minecraft-server-backup@" = {
          unitConfig = {
            Description = "Minecraft Server Backup Task - %i";
            ConditionDirectoryNotEmpty = "${cfg.dataDir}/%i";
            PartOf = "minecraft-server@%i.service";
          };

          serviceConfig = {
            Type = "oneshot";

            ExecStartPre = "${pkgs.writeShellScript "minecraft-server-backup-pre" ''
              if [ $# -ne 3 ]; then
                  echo "Must supply server name and backup path"
                  exit 1
              fi

              SERVER_NAME=$1
              SERVER_DIR=$2
              BACKUP_PATH=$3
              SOCKET="${runDir}/$SERVER_NAME.stdin"

              ${pkgs.coreutils}/bin/mkdir -p ''${BACKUP_PATH}

              if [ -p "$SOCKET" ]; then
                echo "say Running backup..." > "$SOCKET"
                echo "save-off" > "$SOCKET"
                sleep 2
                echo "save-all" > "$SOCKET"

                if [ -f "$SERVER_DIR/logs/latest.log" ]; then
                  ${pkgs.coreutils}/bin/timeout 60 sh -c '
                      stdbuf -oL tail -n2 -f "$1" | sed "/Saved the game/q"
                    ' sh "$SERVER_DIR/logs/latest.log" || true
                fi
              fi
            ''} \"%i\" \"\${SERVER_DIR}\" \"\${BACKUP_PATH}\"";

            ExecStart = "${
              lib.getExe (
                pkgs.writeShellApplication {
                  name = "minecraft-server-backup";
                  runtimeInputs = with pkgs; [
                    gnutar
                    xz
                  ];
                  text = ''
                    if [ $# -ne 3 ]; then
                        echo "Must supply server name and backup path"
                        exit 1
                    fi

                    SERVER_NAME=$1
                    SERVER_DIR=$2
                    BACKUP_PATH=$3
                    DATE=$(date +"%F_%H-%M-%S")

                    tar \
                      --exclude=backup \
                      --exclude=cache \
                      --exclude=crash-reports \
                      --exclude=debug \
                      --exclude=libraries \
                      --exclude=logs \
                      --exclude=versions \
                      --exclude=.env \
                      -cJf "$BACKUP_PATH/$SERVER_NAME-$DATE".tar.xz \
                      -C "$SERVER_DIR" .
                  '';
                }
              )
            } \"%i\" \"\${SERVER_DIR}\" \"\${BACKUP_PATH}\"";

            ExecStopPost = "${pkgs.writeShellScript "minecraft-server-backup-post" ''
              if [ $# -ne 2 ]; then
                  echo "Must supply server name and backup path"
                  exit 1
              fi

              SERVER_NAME=$1
              BACKUP_PATH=$2
              SOCKET="${runDir}/$SERVER_NAME.stdin"

              if [ -p "$SOCKET" ]; then
                echo "save-on" > "$SOCKET"
                echo "say Backup complete." > "$SOCKET"
              fi
            ''} \"%i\" \"\${BACKUP_PATH}\"";

            WorkingDirectory = "${cfg.dataDir}/%i";

            User = cfg.user;
            Group = cfg.user;

            StandardOutput = "journal";
            StandardError = "journal";

            # Set default variables
            Environment = [
              "BACKUP_PATH=${cfg.dataDir}/backups/%i"
              "SERVER_DIR=${cfg.dataDir}/%i"
            ];

            # Override default variable values in environment file
            EnvironmentFile = "-${cfg.dataDir}/%i/.env";

            # Hardening
            CapabilityBoundingSet = [ "" ];
            DeviceAllow = [ "" ];
            PrivateDevices = true;
            LockPersonality = true;
            PrivateTmp = true;
            PrivateUsers = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            PrivateNetwork = true;
            RestrictAddressFamilies = "none";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            UMask = "0077";
            ProtectSystem = "strict";
            ReadWritePaths = [
              "${cfg.dataDir}/backups"
              "${cfg.dataDir}/%i"
              "-${runDir}/%i.stdin"
            ];
            NoNewPrivileges = true;
            RemoveIPC = true;
          };
        };
      };

    systemd.sockets."minecraft-server@" = {
      bindsTo = [ "minecraft-server@%i.service" ];
      socketConfig = {
        Service = "minecraft-server@%i.service";
        ListenFIFO = "${runDir}/%i.stdin";
        SocketMode = "0600";
        SocketUser = cfg.user;
        SocketGroup = cfg.user;
        RemoveOnStop = true;
        FlushPending = true;
      };
    };

    systemd.timers = (mapAttrs' mkBackupTimerOverride backupServers) // {
      "minecraft-server-backup@" = {
        unitConfig.Description = "Minecraft Server Backup Task Schedule - %i";
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          Unit = "minecraft-server-backup@%i.service";
        };
      };
    };

    # Sudo permissions
    security.sudo.extraRules = mkIf cfg.sudoRules (
      let
        # https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
        serviceBaseNameRE = "minecraft-server(-backup)?";
        validUnitNameRE = "[[:alnum:]:_.\\\\-]+(\\.service)?";
        serviceNameRE = "${serviceBaseNameRE}@${validUnitNameRE}";
        commandRE = "(start|stop|restart|status)";
        systemctlArgsRE = "${commandRE}[[:space:]]+${serviceNameRE}";
      in
      [
        {
          groups = [ cfg.user ];
          commands =
            map
              (systemctl: {
                options = [ "NOPASSWD" ];
                command = "${systemctl} ^${systemctlArgsRE}$";
              })
              [
                "${pkgs.systemd}/bin/systemctl"
                "/run/current-system/sw/bin/systemctl"
                "/etc/profiles/per-user/*/bin/systemctl"
              ];
        }
      ]
    );
  };

}

{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.services.postgresql;

  # see description of extraPlugins
  postgresqlAndPlugins = pg:
    if cfg.extraPlugins == [] then pg
    else pkgs.buildEnv {
      name = "postgresql-and-plugins-${(builtins.parseDrvName pg.name).version}";
      paths = [ pg pg.lib ] ++ cfg.extraPlugins;
      # We include /bin to ensure the $out/bin directory is created which is
      # needed because we'll be removing files from that directory in postBuild
      # below. See #22653
      pathsToLink = [ "/" "/bin" ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild =
        ''
          rm $out/bin/{pg_config,postgres,pg_ctl}
          cp --target-directory=$out/bin ${pg}/bin/{postgres,pg_config,pg_ctl}
          wrapProgram $out/bin/postgres --set NIX_PGLIBDIR $out/lib
        '';
    };

  postgresql = postgresqlAndPlugins cfg.package;

  # The main PostgreSQL configuration file.
  configFile = pkgs.writeText "postgresql.conf"
    ''
      hba_file = '${pkgs.writeText "pg_hba.conf" cfg.authentication}'
      ident_file = '${pkgs.writeText "pg_ident.conf" cfg.identMap}'
      log_destination = 'stderr'
      listen_addresses = '${if cfg.enableTCPIP then "*" else "localhost"}'
      port = ${toString cfg.port}
      ${cfg.extraConfig}
    '';

in

{

  ###### interface

  options = {

    services.postgresql = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run PostgreSQL.
        '';
      };

      package = mkOption {
        type = types.package;
        example = literalExample "pkgs.postgresql_9_6";
        description = ''
          PostgreSQL package to use.
        '';
      };

      port = mkOption {
        type = types.int;
        default = 5432;
        description = ''
          The port on which PostgreSQL listens.
        '';
      };

      dataDir = mkOption {
        type = types.path;
        example = "/var/lib/postgresql/9.6";
        description = ''
          Data directory for PostgreSQL.
        '';
      };

      authentication = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Defines how users authenticate themselves to the server. By
          default, "trust" access to local users will always be granted
          along with any other custom options. If you do not want this,
          set this option using "lib.mkForce" to override this
          behaviour.
        '';
      };

      identMap = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Defines the mapping from system users to database users.
        '';
      };

      initialScript = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          A file containing SQL statements to execute on first startup.
        '';
      };

      ensureDatabases = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Ensures that the specified databases exist.
          This option will never delete existing databases, especially not when the value of this
          option is changed. This means that databases created once through this option or
          otherwise have to be removed manually.
        '';
        example = [
          "gitea"
          "nextcloud"
        ];
      };

      ensureUsers = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = ''
                Name of the user to ensure.
              '';
            };
            ensurePermissions = mkOption {
              type = types.attrsOf types.str;
              default = {};
              description = ''
                Permissions to ensure for the user, specified as an attribute set.
                The attribute names specify the database and tables to grant the permissions for.
                The attribute values specify the permissions to grant. You may specify one or
                multiple comma-separated SQL privileges here.

                For more information on how to specify the target
                and on which privileges exist, see the
                <link xlink:href="https://www.postgresql.org/docs/current/sql-grant.html">GRANT syntax</link>.
                The attributes are used as <code>GRANT ''${attrName} ON ''${attrValue}</code>.
              '';
              example = literalExample ''
                {
                  "DATABASE nextcloud" = "ALL PRIVILEGES";
                  "ALL TABLES IN SCHEMA public" = "ALL PRIVILEGES";
                }
              '';
            };
          };
        });
        default = [];
        description = ''
          Ensures that the specified users exist and have at least the ensured permissions.
          The PostgreSQL users will be identified using peer authentication. This authenticates the Unix user with the
          same name only, and that without the need for a password.
          This option will never delete existing users or remove permissions, especially not when the value of this
          option is changed. This means that users created and permissions assigned once through this option or
          otherwise have to be removed manually.
        '';
        example = literalExample ''
          [
            {
              name = "nextcloud";
              ensurePermissions = {
                "DATABASE nextcloud" = "ALL PRIVILEGES";
              };
            }
            {
              name = "superuser";
              ensurePermissions = {
                "ALL TABLES IN SCHEMA public" = "ALL PRIVILEGES";
              };
            }
          ]
        '';
      };

      enableTCPIP = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether PostgreSQL should listen on all network interfaces.
          If disabled, the database can only be accessed via its Unix
          domain socket or via TCP connections to localhost.
        '';
      };

      extraPlugins = mkOption {
        type = types.listOf types.path;
        default = [];
        example = literalExample "[ (pkgs.postgis.override { postgresql = pkgs.postgresql_9_4; }) ]";
        description = ''
          When this list contains elements a new store path is created.
          PostgreSQL and the elements are symlinked into it. Then pg_config,
          postgres and pg_ctl are copied to make them use the new
          $out/lib directory as pkglibdir. This makes it possible to use postgis
          without patching the .sql files which reference $libdir/postgis-1.5.
        '';
        # Note: the duplication of executables is about 4MB size.
        # So a nicer solution was patching postgresql to allow setting the
        # libdir explicitely.
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Additional text to be appended to <filename>postgresql.conf</filename>.";
      };

      recoveryConfig = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          Contents of the <filename>recovery.conf</filename> file.
        '';
      };
      superUser = mkOption {
        type = types.str;
        default= if versionAtLeast config.system.stateVersion "17.09" then "postgres" else "root";
        internal = true;
        description = ''
          NixOS traditionally used 'root' as superuser, most other distros use 'postgres'.
          From 17.09 we also try to follow this standard. Internal since changing this value
          would lead to breakage while setting up databases.
        '';
        };
    };

  };


  ###### implementation

  config = mkIf config.services.postgresql.enable {

    services.postgresql.package =
      # Note: when changing the default, make it conditional on
      # ‘system.stateVersion’ to maintain compatibility with existing
      # systems!
      mkDefault (if versionAtLeast config.system.stateVersion "17.09" then pkgs.postgresql_9_6
            else if versionAtLeast config.system.stateVersion "16.03" then pkgs.postgresql_9_5
            else pkgs.postgresql_9_4);

    services.postgresql.dataDir =
      mkDefault (if versionAtLeast config.system.stateVersion "17.09" then "/var/lib/postgresql/${config.services.postgresql.package.psqlSchema}"
                 else "/var/db/postgresql");

    services.postgresql.authentication = mkAfter
      ''
        # Generated file; do not edit!
        local all all              ident
        host  all all 127.0.0.1/32 md5
        host  all all ::1/128      md5
      '';

    users.users.postgres =
      { name = "postgres";
        uid = config.ids.uids.postgres;
        group = "postgres";
        description = "PostgreSQL server user";
        home = "${cfg.dataDir}";
        useDefaultShell = true;
      };

    users.groups.postgres.gid = config.ids.gids.postgres;

    environment.systemPackages = [ postgresql ];

    systemd.services.postgresql =
      { description = "PostgreSQL Server";

        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        environment.PGDATA = cfg.dataDir;

        path = [ postgresql ];

        preStart =
          ''
            # Create data directory.
            if ! test -e ${cfg.dataDir}/PG_VERSION; then
              mkdir -m 0700 -p ${cfg.dataDir}
              rm -f ${cfg.dataDir}/*.conf
              chown -R postgres:postgres ${cfg.dataDir}
            fi
          ''; # */

        script =
          ''
            # Initialise the database.
            if ! test -e ${cfg.dataDir}/PG_VERSION; then
              initdb -U ${cfg.superUser}
              # See postStart!
              touch "${cfg.dataDir}/.first_startup"
            fi
            ln -sfn "${configFile}" "${cfg.dataDir}/postgresql.conf"
            ${optionalString (cfg.recoveryConfig != null) ''
              ln -sfn "${pkgs.writeText "recovery.conf" cfg.recoveryConfig}" \
                "${cfg.dataDir}/recovery.conf"
            ''}

             exec postgres
          '';

        serviceConfig =
          { ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            User = "postgres";
            Group = "postgres";
            PermissionsStartOnly = true;
            RuntimeDirectory = "postgresql";
            Type = if lib.versionAtLeast cfg.package.version "9.6"
                   then "notify"
                   else "simple";

            # Shut down Postgres using SIGINT ("Fast Shutdown mode").  See
            # http://www.postgresql.org/docs/current/static/server-shutdown.html
            KillSignal = "SIGINT";
            KillMode = "mixed";

            # Give Postgres a decent amount of time to clean up after
            # receiving systemd's SIGINT.
            TimeoutSec = 120;
          };

        # Wait for PostgreSQL to be ready to accept connections.
        postStart =
          ''
            PSQL="${pkgs.sudo}/bin/sudo -u ${cfg.superUser} psql --port=${toString cfg.port}"

            while ! $PSQL -d postgres -c "" 2> /dev/null; do
                if ! kill -0 "$MAINPID"; then exit 1; fi
                sleep 0.1
            done

            if test -e "${cfg.dataDir}/.first_startup"; then
              ${optionalString (cfg.initialScript != null) ''
                $PSQL -f "${cfg.initialScript}" -d postgres
              ''}
              rm -f "${cfg.dataDir}/.first_startup"
            fi
          '' + optionalString (cfg.ensureDatabases != []) ''
            ${concatMapStrings (database: ''
              $PSQL -tAc "SELECT 1 FROM pg_database WHERE datname = '${database}'" | grep -q 1 || $PSQL -tAc "CREATE DATABASE ${database}"
            '') cfg.ensureDatabases}
          '' + ''
            ${concatMapStrings (user: ''
              $PSQL -tAc "SELECT 1 FROM pg_roles WHERE rolname='${user.name}'" | grep -q 1 || $PSQL -tAc "CREATE USER ${user.name}"
              ${concatStringsSep "\n" (mapAttrsToList (database: permission: ''
                $PSQL -tAc "GRANT ${permission} ON ${database} TO ${user.name}"
              '') user.ensurePermissions)}
            '') cfg.ensureUsers}
          '';

        unitConfig.RequiresMountsFor = "${cfg.dataDir}";
      };

  };

  meta.doc = ./postgresql.xml;
  meta.maintainers = with lib.maintainers; [ thoughtpolice ];
}

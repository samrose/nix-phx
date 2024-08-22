{
  description = "Phoenix Framework project with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    in
    flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        
        # Phoenix application name (change this to match your app name)
        appName = "phxapp";

        # Phoenix release build
        phoenixRelease = let
          packages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_25;
        in packages.mixRelease rec {
          pname = appName;
          version = "0.0.0";
          src = ./.;
          MIX_ENV = "prod";
          mixFodDeps = packages.fetchMixDeps {
            inherit version src pname;
            sha256 = "sha256-7VqkdolqEjF9a0A/S4dyyB7y7fYBuEVIpNICWHFfj+Y=";
            buildInputs = [];
            propagatedBuildInputs = [];
          };
        };

        # Development shell
        devShell = let
          basePackages = with pkgs; [
            alejandra
            bat
            erlang_25
            elixir_1_16
            docker-compose
            entr
            gnumake
            overmind
            jq
            mix2nix
            (postgresql_16.withPackages (p: [p.postgis]))
            graphviz
            imagemagick
            python3
            glibcLocales
          ] ++ lib.optionals stdenv.isLinux [
            inotify-tools
            unixtools.netstat
          ] ++ lib.optionals stdenv.isDarwin [
            terminal-notifier
            darwin.apple_sdk.frameworks.CoreFoundation
            darwin.apple_sdk.frameworks.CoreServices
          ];

          postgresInitScript = if pkgs.stdenv.isDarwin then ''
            if [ ! -d $PGDATA ]; then
              echo 'Initializing postgresql database...'
              initdb --auth=trust -U postgres $PGDATA --encoding=UTF8 --locale=en_US.UTF-8
              echo "listen_addresses='*'" >> $PGDATA/postgresql.conf
              echo "unix_socket_directories='$PWD/postgres'" >> $PGDATA/postgresql.conf
              echo "unix_socket_permissions=0700" >> $PGDATA/postgresql.conf
              echo "port = 5432" >> $PGDATA/postgresql.conf
            fi
          '' else ''
            if [ ! -d $PGDATA ]; then
              echo 'Initializing postgresql database...'
              initdb $PGDATA --username postgres -A trust --encoding=UTF8 --locale=en_US.UTF-8
              echo "listen_addresses='*'" >> $PGDATA/postgresql.conf
              echo "unix_socket_directories='$PWD/postgres'" >> $PGDATA/postgresql.conf
              echo "unix_socket_permissions=0700" >> $PGDATA/postgresql.conf
              echo "port = 5432" >> $PGDATA/postgresql.conf
            fi
          '';

          hooks = ''
            # Check if .env file exists before sourcing
            # if [ -f .env ]; then
            #   source .env
            # else
            #   echo ".env file not found. Skipping..."
            # fi
            mkdir -p .nix-mix .nix-hex
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-mix
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            export LANG=en_US.UTF-8
            export LC_ALL=en_US.UTF-8
            export ERL_AFLAGS="-kernel shell_history enabled"
            export PGDATA=$PWD/postgres_data
            export PGHOST=$PWD/postgres
            export LOG_PATH=$PWD/postgres/LOG

            export PGUSER=postgres
            export PGPASSWORD=postgres
            export PGDATABASE=postgres
            export PGPORT=5432
            export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/postgres"
            if [ ! -d $PWD/postgres ]; then
              mkdir -p $PWD/postgres
            fi
            export DATABASE_URL="postgresql:///postgres?host=$PGHOST&port=5434"
            if [ ! -d $PWD/postgres ]; then
              mkdir -p $PWD/postgres
            fi
            ${postgresInitScript}
            echo 'To run the services configured here, you can run the `overmind start -D` command'
            echo 'To connect to PostgreSQL, use: psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE'
          '';
        in pkgs.mkShell {
          buildInputs = basePackages;
          shellHook = hooks;
          LOCALE_ARCHIVE = if pkgs.stdenv.isLinux then "${pkgs.glibcLocales}/lib/locale/locale-archive" else "";
        };

      in {
        packages.default = phoenixRelease;

        devShells.default = devShell;

        # NixOS module for the Phoenix application
        nixosModules.default = { config, lib, pkgs, ... }:
          with lib;
          let cfg = config.services.${appName};
          in {
            options.services.${appName} = {
              enable = mkEnableOption "Phoenix application service";
              port = mkOption {
                type = types.port;
                default = 4000;
                description = "Port to run the Phoenix application on";
              };
              user = mkOption {
                type = types.str;
                default = "${appName}";
                description = "User to run the Phoenix application as";
              };
              group = mkOption {
                type = types.str;
                default = "${appName}";
                description = "Group to run the Phoenix application as";
              };
            };

            config = mkIf cfg.enable {
              systemd.services.${appName} = {
                description = "Phoenix Application Service";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" "postgresql.service" ];
                environment = {
                  PORT = toString cfg.port;
                  RELEASE_NAME = appName;
                };
                serviceConfig = {
                  Type = "simple";
                  User = cfg.user;
                  Group = cfg.group;
                  ExecStart = "${phoenixRelease}/bin/${appName} start";
                  Restart = "on-failure";
                };
              };

              users.users.${cfg.user} = {
                isSystemUser = true;
                group = cfg.group;
              };
              users.groups.${cfg.group} = {};

              # PostgreSQL configuration
              services.postgresql = {
                enable = true;
                package = pkgs.postgresql_16;
                ensureDatabases = [ "${appName}" ];
                ensureUsers = [
                  {
                    name = "${appName}";
                    ensurePermissions = {
                      "DATABASE ${appName}" = "ALL PRIVILEGES";
                    };
                  }
                ];
              };
            };
          };

        # NixOS configuration using the module (only for Linux systems)
        nixosConfigurations = pkgs.lib.optionalAttrs (pkgs.stdenv.isLinux) {
          default = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              ({ ... }: {
                services.${appName}.enable = true;
                services.${appName}.port = 4000;
              })
            ];
          };
        };

        # Flake checks
        checks = {
          build = self.packages.${system}.default;
        };
      });
}
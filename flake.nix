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

        # Phoenix release build configuration remains the same...
        phoenixRelease =
          let
            packages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_25 pkgs.elixir_1_17;
          in
          packages.mixRelease rec {
            pname = appName;
            version = "0.0.0";
            src = ./.;
            MIX_ENV = "prod";
            mixFodDeps = packages.fetchMixDeps {
              inherit version src pname;
              sha256 = "sha256-7VqkdolqEjF9a0A/S4dyyB7y7fYBuEVIpNICWHFfj+Y=";
              buildInputs = [ ];
              propagatedBuildInputs = [ ];
            };
          };

        devShellScript = pkgs.writeText "devshell.nu" ''
          # Create .nushell directory if it doesn't exist
          mkdir .nushell
  
          # Environment setup
          mkdir .nix-mix .nix-hex
          $env.MIX_HOME = ($env.PWD | path join ".nix-mix")
          $env.HEX_HOME = ($env.PWD | path join ".nix-hex")
  
          # Properly construct PATH using nushell list operations
          let mix_bin = ($env.MIX_HOME | path join "bin")
          let hex_bin = ($env.HEX_HOME | path join "bin")
          $env.PATH = ([$mix_bin $hex_bin] | append ($env.PATH | split row (char esep)) | uniq | str join (char esep))
  
          $env.LANG = "en_US.UTF-8"
          $env.LC_ALL = "en_US.UTF-8"
          $env.ERL_AFLAGS = "-kernel shell_history enabled"
          $env.PGDATA = ($env.PWD | path join "postgres_data")
          $env.PGHOST = ($env.PWD | path join "postgres")
          $env.LOG_PATH = ($env.PGHOST | path join "LOG")

          $env.PGUSER = "postgres"
          $env.PGPASSWORD = "postgres"
          $env.PGDATABASE = "postgres"
          $env.PGPORT = "5432"
          $env.DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/postgres"

          # Create postgres directory if it doesn't exist
          if not ($env.PGHOST | path exists) {
            mkdir $env.PGHOST
          }

          # PostgreSQL initialization
          if not ($env.PGDATA | path exists) {
            print 'Initializing postgresql database...'
            if $env.OS == "macos" {
              initdb --auth=trust -U postgres $env.PGDATA --encoding=UTF8 --locale=en_US.UTF-8
            } else {
              initdb $env.PGDATA --username postgres -A trust --encoding=UTF8 --locale=en_US.UTF-8
            }
    
            # Configure PostgreSQL
            $"listen_addresses='*'" | save --append $env.PGDATA/postgresql.conf
            $"unix_socket_directories='($env.PWD)/postgres'" | save --append $env.PGDATA/postgresql.conf
            "unix_socket_permissions=0700" | save --append $env.PGDATA/postgresql.conf
            "port = 5432" | save --append $env.PGDATA/postgresql.conf
          }

          # Print helpful information
          print "To run the services configured here, you can run the `overmind start -D` command"
          print $"To connect to PostgreSQL, use: psql -h ($env.PGHOST) -p ($env.PGPORT) -U ($env.PGUSER) -d ($env.PGDATABASE)"
        '';
        # Basic env.nu config
        nuEnvConfig = pkgs.writeText "env.nu" ''
          # Ensure we use project config
          $env.NUSHELL_CONFIG_DIR = ($env.PWD | path join ".nushell")
          $env.config = {
            show_banner: false
            edit_mode: emacs
            shell_integration: true
            use_ansi_coloring: true
          }
        '';

        # Basic config.nu
        nuConfig = pkgs.writeText "config.nu" ''
          # Basic configuration
          $env.config = {
            show_banner: false
            edit_mode: emacs
            shell_integration: true
            use_ansi_coloring: true
          }
        '';

        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            nixpkgs-fmt
            bat
            erlang_25
            elixir_1_17
            docker-compose
            entr
            gnumake
            overmind
            jq
            mix2nix
            (postgresql_16.withPackages (p: [ p.postgis ]))
            graphviz
            imagemagick
            python3
            glibcLocales
            nushell
          ] ++ lib.optionals stdenv.isLinux [
            inotify-tools
            unixtools.netstat
          ] ++ lib.optionals stdenv.isDarwin [
            terminal-notifier
            darwin.apple_sdk.frameworks.CoreFoundation
            darwin.apple_sdk.frameworks.CoreServices
          ];

          shellHook = ''
            # Copy config files
            mkdir -p "$PWD/.nushell"
            cp ${nuEnvConfig} "$PWD/.nushell/env.nu"
            cp ${nuConfig} "$PWD/.nushell/config.nu"
            
            # Start nushell with our custom config
            NUSHELL_CONFIG_DIR="$PWD/.nushell" ${pkgs.nushell}/bin/nu ${devShellScript}
            exec env NUSHELL_CONFIG_DIR="$PWD/.nushell" ${pkgs.nushell}/bin/nu
          '';

          LOCALE_ARCHIVE = if pkgs.stdenv.isLinux then "${pkgs.glibcLocales}/lib/locale/locale-archive" else "";
        };

      in
      {
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
              users.groups.${cfg.group} = { };

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

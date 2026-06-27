{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      eachSystem =
        f:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (
          system: f system nixpkgs.legacyPackages.${system}
        );

      # The container that runs on Fly. Fly Machines are x86_64-linux only,
      # so the image must target that system regardless of the build host.
      mkImage =
        pkgs:
        let
          # Orchestration scripts. writeShellApplication runs shellcheck at build
          # time and gives each script its own PATH via runtimeInputs.
          bootstrap = pkgs.writeShellApplication {
            name = "outpost-bootstrap";
            runtimeInputs = with pkgs; [ opencode gitMinimal openssh coreutils ];
            text = builtins.readFile ./scripts/bootstrap.sh;
          };
          idleWatcher = pkgs.writeShellApplication {
            name = "outpost-idle-watcher";
            runtimeInputs = with pkgs; [ curl jq coreutils process-compose procps ];
            text = builtins.readFile ./scripts/idle-watcher.sh;
          };

          # Tools available inside the container, unioned under /bin. opencode
          # shells out to git/ssh/curl, so those must live on the global PATH —
          # not just inside the scripts above.
          root = pkgs.buildEnv {
            name = "outpost-root";
            paths = with pkgs; [
              opencode
              gitMinimal
              openssh
              curl
              jq
              inotify-tools # gitwatch's change detector
              gitwatch
              process-compose
              bashInteractive
              coreutils
              cacert
              bootstrap
              idleWatcher
              # opencode web auto-opens a browser via xdg-open; on this headless
              # box that errors out. A no-op shim makes the auto-open harmless.
              (writeShellScriptBin "xdg-open" "exit 0")
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "outpost";
          tag = "latest";
          contents = [
            root
            # ssh (used by git clone) calls getpwuid(0); a dockerTools image has no
            # /etc/passwd, so root is unresolvable -> "No user exists for uid 0".
            # fakeNss provides a minimal passwd/group with root + nobody.
            pkgs.fakeNss
          ];
          config = {
            Env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # The Fly Volume is mounted here; opencode state + the wiki repo live
              # under it, so both persist across scale-to-zero.
              "HOME=/root"
              # Shared by bootstrap, opencode (working dir) and idle-watcher.
              "WIKI=/root/llm-wiki"
              # gitwatch's wrapped git runs with a reduced PATH/HOME, so relying
              # on ssh defaults (PATH lookup + ~/.ssh) is fragile. Pin everything:
              # absolute ssh, the deploy key, and the pinned known_hosts file.
              "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/root/.ssh/known_hosts"
            ];
            # process-compose supervises bootstrap (one-shot) + opencode + gitwatch
            # + idle-watcher. --port avoids clashing its own API with opencode:8080.
            Cmd = [
              "/bin/process-compose"
              "-f"
              "${./process-compose.yaml}"
              "up"
              "--tui=false"
              "--port"
              "8099"
            ];
          };
        };
    in
    {
      packages = eachSystem (
        _system: pkgs:
          # buildLayeredImage produces a Linux image; only expose it where it can build.
          nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            image = mkImage pkgs;
            default = mkImage pkgs;
          }
      );

      devShells = eachSystem (_system: pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.flyctl
          ];
        };
      });
    };
}

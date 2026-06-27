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
          # Tools available inside the container, unioned under /bin.
          root = pkgs.buildEnv {
            name = "outpost-root";
            paths = with pkgs; [
              opencode
              gitMinimal
              curl
              bashInteractive
              coreutils
              cacert
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
          contents = [ root ];
          config = {
            Env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # The Fly Volume is mounted here; opencode state + the wiki repo live
              # under it, so both persist across scale-to-zero.
              "HOME=/root"
            ];
            # Run opencode's headless web server. The phone hits the built-in web
            # UI over Fly's TLS; OPENCODE_SERVER_PASSWORD gates it with Basic Auth.
            Cmd = [
              "/bin/bash"
              "-c"
              ''
                set -u
                echo "=== outpost container up ==="
                echo "opencode: $(opencode --version 2>&1 || true)"
                echo "git:      $(git --version)"
                echo "curl:     $(curl --version | head -n1)"

                # HOME is the Fly Volume mount point (/root). Prove it persists:
                # append a boot line and print the running history.
                mkdir -p "$HOME"
                echo "boot at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HOME/boots.log"
                echo "=== $HOME/boots.log (volume persistence history) ==="
                cat "$HOME/boots.log"

                # Confirm runtime secret injection WITHOUT leaking values.
                echo "=== secrets present? (set / unset only, values never printed) ==="
                for v in GIT_DEPLOY_KEY OPENCODE_SERVER_PASSWORD; do
                  if [ -n "''${!v:-}" ]; then echo "$v: set"; else echo "$v: unset"; fi
                done

                # opencode's working dir is the wiki repo. Cloning it (via the
                # deploy key) is a later task; for now just ensure the dir exists
                # so opencode has somewhere to run.
                WIKI="$HOME/llm-wiki"
                mkdir -p "$WIKI"
                cd "$WIKI"

                echo "=== starting opencode web on :8080 (wd: $WIKI) ==="
                exec opencode web --hostname 0.0.0.0 --port 8080
              ''
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

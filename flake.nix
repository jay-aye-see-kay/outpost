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
              pi-coding-agent
              gitMinimal
              curl
              bashInteractive
              coreutils
              cacert
              darkhttpd
            ];
            pathsToLink = [
              "/bin"
              "/etc"
            ];
          };

          # Demo landing page served over Fly's HTTPS. Replace with the paseo
          # daemon once it's wired up.
          webroot = pkgs.runCommand "outpost-webroot" { } ''
            mkdir -p $out
            cat > $out/index.html <<'HTML'
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>outpost</title>
              <style>
                body { font-family: system-ui, sans-serif; max-width: 32rem;
                       margin: 4rem auto; padding: 0 1rem; line-height: 1.5; }
              </style>
            </head>
            <body>
              <h1>outpost is up</h1>
              <p>Personal LLM wiki — demo service running on Fly.io.</p>
              <p>This static page is a placeholder for the paseo daemon.</p>
            </body>
            </html>
            HTML
          '';
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "outpost";
          tag = "latest";
          contents = [ root ];
          config = {
            Env = [
              "PATH=/bin"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            # Task 2: serve a demo page over Fly's HTTPS on the http_service port.
            Cmd = [
              "/bin/bash"
              "-c"
              ''
                echo "=== outpost container up ==="
                echo "pi:   $(pi --version 2>&1 || true)"
                echo "git:  $(git --version)"
                echo "curl: $(curl --version | head -n1)"
                echo "=== serving demo page on :8080 (replace with paseo daemon later) ==="

                # Prove the Fly Volume persists across restarts: append a boot line
                # and print the running history. This file lives on /data (the volume).
                mkdir -p /data
                echo "boot at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /data/boots.log
                echo "=== /data/boots.log (volume persistence history) ==="
                cat /data/boots.log

                # Confirm runtime secret injection WITHOUT leaking values.
                echo "=== secrets present? (set / unset only, values never printed) ==="
                for v in ANTHROPIC_API_KEY PASEO_PASSWORD GIT_DEPLOY_KEY; do
                  if [ -n "''${!v:-}" ]; then echo "$v: set"; else echo "$v: unset"; fi
                done

                exec darkhttpd ${webroot} --port 8080 --addr 0.0.0.0
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

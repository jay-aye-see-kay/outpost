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
            ];
            # Task 1: prove the image runs on Fly and the tools are present.
            Cmd = [
              "/bin/bash"
              "-c"
              ''
                echo "=== outpost container up ==="
                echo "pi:   $(pi --version 2>&1 || true)"
                echo "git:  $(git --version)"
                echo "curl: $(curl --version | head -n1)"
                echo "=== idling (replace with paseo daemon later) ==="
                while true; do sleep 3600; done
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

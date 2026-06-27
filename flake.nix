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
              openssh
              curl
              bashInteractive
              coreutils
              cacert
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

                # Set up the GitHub deploy key so git can talk to the private repo
                # over SSH. Key comes from the GIT_DEPLOY_KEY secret (never baked in).
                # GitHub's host key is pinned (no blind StrictHostKeyChecking=no).
                install -d -m 700 "$HOME/.ssh"
                if [ -n "''${GIT_DEPLOY_KEY:-}" ]; then
                  printf '%s\n' "$GIT_DEPLOY_KEY" > "$HOME/.ssh/id_ed25519"
                  chmod 600 "$HOME/.ssh/id_ed25519"
                fi
                cat > "$HOME/.ssh/known_hosts" <<'KNOWN'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
KNOWN
                chmod 644 "$HOME/.ssh/known_hosts"
                export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts"

                # opencode's working dir is the wiki repo. Clone it on first boot
                # (empty volume); on later boots gitwatch keeps it in sync.
                WIKI="$HOME/llm-wiki"
                if [ ! -d "$WIKI/.git" ]; then
                  if [ -n "''${WIKI_REPO:-}" ]; then
                    echo "=== cloning $WIKI_REPO into $WIKI ==="
                    git clone "$WIKI_REPO" "$WIKI" || { echo "clone FAILED"; mkdir -p "$WIKI"; }
                  else
                    echo "=== WIKI_REPO unset; starting with an empty $WIKI ==="
                    mkdir -p "$WIKI"
                  fi
                fi
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

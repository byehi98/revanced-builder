{
  description = "ReVanced Builder dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # utils.sh defines: java() { env -i java "$@"; }
        # GNU env -i replaces its own environ before execvp, so the
        # fallback search path (/usr/local/bin:/bin:/usr/bin) is used
        # instead of the nix-shell PATH. This wrapper preserves PATH
        # when -i is used so nix-store binaries remain findable.
        envWrapper = pkgs.writeShellScriptBin "env" ''
          case "$1" in
            -i) shift; exec ${pkgs.coreutils}/bin/env -i PATH="$PATH" "$@" ;;
            *)  exec ${pkgs.coreutils}/bin/env "$@" ;;
          esac
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            envWrapper
            jdk17
            jq
            zip
            unzip
            curl
            gnused
            gawk
            coreutils
            findutils
            gnugrep
          ];

          shellHook = ''
            export JAVA_HOME="${pkgs.jdk17}/lib/openjdk"
          '';
        };
      });
}

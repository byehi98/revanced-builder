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

        # nixpkgs-unstable still carries apkeep 0.18.0, so take the published
        # binary directly instead. Bump this with the two hashes when a new
        # tag lands (`nix hash file --type sha256 --base64 <asset>`).
        #
        # dl_apkeep only ever uses apkeep's apk-pure source, so verify that
        # one after bumping:
        #   apkeep -a com.example.app@1.2.3 -d apk-pure -o acknowledge_dangers=true out/
        apkeepVersion = "1.1.0";

        apkeepAssets = {
          x86_64-linux = {
            url = "https://github.com/EFForg/apkeep/releases/download/${apkeepVersion}/apkeep-x86_64-unknown-linux-gnu";
            hash = "sha256-ut162fp9LzKr4B6vM7f/CGNhqVu8AAozv0S2MNS/IUA=";
          };
          aarch64-linux = {
            url = "https://github.com/EFForg/apkeep/releases/download/${apkeepVersion}/apkeep-aarch64-unknown-linux-gnu";
            hash = "sha256-Gi6VmEK7ykvI20VbgTLMbzdTTXDyOEQJCWJo2PxEKug=";
          };
        };

        # apkeep ships linux-android, linux-gnu and windows-msvc assets only,
        # so anything else (notably darwin) falls back to the nixpkgs build.
        apkeepAsset = apkeepAssets.${system} or null;

        apkeepLatest = pkgs.runCommand "apkeep-${apkeepVersion}"
          {
            version = apkeepVersion;
            passthru = {
              inherit apkeepVersion;
              homepage = "https://github.com/EFForg/apkeep";
            };
          } ''
          mkdir -p "$out/bin"
          cp ${pkgs.fetchurl { inherit (apkeepAsset) url hash; }} "$out/bin/apkeep"
          chmod +x "$out/bin/apkeep"
        '';

        apkeep =
          if apkeepAsset != null
          then apkeepLatest
          else pkgs.apkeep;

        # utils.sh defines: java() { env -i PATH="$PATH" HOME="$HOME" java ...; }
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
            jdk21
            jq
            zip
            unzip
            curl
            gnused
            gawk
            coreutils
            findutils
            gnugrep
            util-linux # flock, used by _with_lock() in utils.sh
            pipx
          ] ++ [ apkeep ];

          shellHook = ''
            export JAVA_HOME="${pkgs.jdk21}/lib/openjdk"
          '';
        };
      });
}

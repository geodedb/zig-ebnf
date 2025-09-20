{
  description = "dev";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    dev-env.url = "github:spyderorg/dev-env";
    quic.url = "github:spyderorg/quic";
  };

  outputs =
    {
      self,
      nixpkgs,
      dev-env,
      quic,
      flake-utils,
      ...
    }:
    let
      flakeForSystem =
        nixpkgs: system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = { allowUnfree = true; };
          };

          zigPkg = dev-env.packages.${system}.zigPackages;
          quicPkg = quic.packages.${system}.quic;
          quicDebugPkg = quic.packages.${system}.quic-debug;

          # Build zcap packages - use dev-env zig (0.15.1)
          zcapPkg = pkgs.callPackage ./nix/zcap.nix {
            zig = zigPkg;
            optimize = "ReleaseFast";
            enableXdp = false;
          };
          
          zcapStaticPkg = pkgs.callPackage ./nix/zcap.nix {
            zig = zigPkg;
            optimize = "ReleaseFast";
            enableXdp = false;
            # For static builds, we might want different flags
          };
          
          # Single source of truth for the development environment packages
          devShellPackages = [
            quicPkg
            quicDebugPkg
            pkgs.zigPkg
            pkgs.tcpdump
            pkgs.file
          ];
        in
        {
          packages = {
            zcap = zcapPkg;
            zcap-static = zcapStaticPkg;
            default = zcapPkg;
          };
          devShell = pkgs.mkShell {
            shellHook = '''';
            env = { };
            packages =
              (with dev-env.packages.${system}; [
                zigPackages
                goPackages
                commonPackages
              ])
              ++ (with pkgs; [
                tcpdump
                tshark
                file
                wine
              ]);
          };
        };
    in
    flake-utils.lib.eachDefaultSystem (system: flakeForSystem nixpkgs system);

  nixConfig = {
    extra-substituters = [ "https://spyder.cachix.org" ];
    extra-trusted-public-keys = [
      "spyder.cachix.org-1:xZG2a8INH6yNyOAwtN2Ojjys0GO9D1pXEe3PNriT04E="
    ];
  };
}

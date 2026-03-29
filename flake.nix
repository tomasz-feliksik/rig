{
  description = "Rig development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
      treefmt-nix,
    }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.rustfmt = {
            enable = true;
            package = rustToolchain;
          };
          programs.prettier = {
            enable = true;
            includes = [ "docs/*.md" "docs/**/*.md" ];
          };
        };
      in
      {
        formatter = treefmtEval.config.build.wrapper;
        checks.formatting = treefmtEval.config.build.check self;

        devShells.default = with pkgs; mkShell {
          buildInputs = [
            pkg-config
            cmake
            just

            openssl
            sqlite
            postgresql
            protobuf

            rustToolchain
            wasm-bindgen-cli
            wasm-pack
          ];

          OPENSSL_DEV = openssl.dev;
          OPENSSL_LIB_DIR = "${openssl.out}/lib";
          OPENSSL_INCLUDE_DIR = "${openssl.dev}/include";
        };
      }
    );
}

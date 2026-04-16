{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
  inputs.opam-nix = {
    url = "github:tweag/opam-nix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
    inputs.opam-repository.follows = "opam-repository";
  };
  inputs.self.submodules = true;
  inputs.opam-repository = {
    url = "github:ocaml/opam-repository";
    flake = false;
  };

  outputs = { self, nixpkgs, opam-nix, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system: rec {
      legacyPackages =
        let 
          inherit (opam-nix.lib.${system}) buildOpamProject';
          scope = buildOpamProject' { pinDepends = true; } ./. { ocaml-base-compiler = "*"; };
        in
        scope;

      packages.default = self.legacyPackages.${system}.solver-service;
      defaultPackage = packages.default;
    });
}

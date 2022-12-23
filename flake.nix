{
  description = "Hydra Auction";

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://hydra-node.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "hydra-node.cachix.org-1:vK4mOEQDQKl9FTbq76NjOuNaRD4pZLxi1yri31HHmIw="
    ];
    allow-import-from-derivation = true;
  };

  inputs = {
    # when you upgrade `hydra` input remember to also upgrade revs under `source-repository-package`s in `cabal.project`
    hydra.url = "github:input-output-hk/hydra/fafb8e5eca0f5fc615f5957ac1243e09c19f9a9f";
    # haskellNix.follows = "hydra/haskellNix";
    haskellNix.url = "github:input-output-hk/haskell.nix";
    iohk-nix.follows = "hydra/iohk-nix";
    CHaP.follows = "hydra/CHaP";
    nixpkgs.follows = "hydra/nixpkgs";
    flake-utils.follows = "hydra/flake-utils";
  };

  outputs = inputs@{ self, hydra, haskellNix, iohk-nix, CHaP, nixpkgs, flake-utils }:
    let
      overlays = [
        haskellNix.overlay
        iohk-nix.overlays.crypto
        (final: prev: {
          hydraProject =
            final.haskell-nix.cabalProject {
              src = final.haskell-nix.haskellLib.cleanGit { src = ./.; name = "hydra-auction"; };
              inputMap = {
                "https://input-output-hk.github.io/cardano-haskell-packages" = CHaP;
              };
              # extraHackage = [
              #   "${plutarch}"
              #   "${plutarch}/plutarch-extra"
              #   "${plutarch}/plutarch-test"
              #   "${ply}/ply-core"
              #   "${ply}/ply-plutarch"
              # ];
              compiler-nix-name = "ghc8107";
              shell.tools = {
                cabal = "3.4.0.0";
                fourmolu = "0.4.0.0";
                haskell-language-server = "latest";
              };
              shell.buildInputs = with final; [
                nixpkgs-fmt
              ];
                modules = [
                    # Set libsodium-vrf on cardano-crypto-{praos,class}. Otherwise they depend
                    # on libsodium, which lacks the vrf functionality.
                    ({ pkgs, lib, ... }:
                        # Override libsodium with local 'pkgs' to make sure it's using
                        # overriden 'pkgs', e.g. musl64 packages
                        {
                        packages.cardano-crypto-class.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf pkgs.secp256k1 ] ];
                        packages.cardano-crypto-praos.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf ] ];
                        }
                    )
                    ];
            };
        })
      ];
    in flake-utils.lib.eachDefaultSystem (system : let
      pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
      haskellNixFlake = pkgs.hydraProject.flake { };
      in {
        packages.default = haskellNixFlake.packages."hydra-auction:exe:hydra-auction";
        inherit (haskellNixFlake) devShells;
      }) // {
      herculesCI = {
        ciSystems = [ "x86_64-linux" ];
        outputs = {
          packages = self.packages.x86_64-linux;
        };
      };
    };
}

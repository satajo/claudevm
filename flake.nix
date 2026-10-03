{
  description = "Run Claude Code with bypassed permissions inside an ephemeral QEMU microVM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.claudevm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nix/guest
          microvm.nixosModules.microvm
        ];
      };

      packages.${system} = {
        broker = pkgs.callPackage ./nix/broker { };
        claudevm = pkgs.callPackage ./nix/claudevm.nix {
          guest = self.nixosConfigurations.claudevm.config;
          broker = self.packages.${system}.broker;
        };
        default = self.packages.${system}.claudevm;
      };

      checks.${system} = {
        inherit (self.packages.${system}) claudevm broker;
        broker-test = pkgs.callPackage ./nix/broker/test.nix {
          broker = self.packages.${system}.broker;
        };
      };
    };
}

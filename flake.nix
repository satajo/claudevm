{
  description = "Run Claude Code with bypassed permissions inside an ephemeral QEMU microVM that shares only the working directory read-write";

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
          microvm.nixosModules.microvm
          ./nix/guest.nix
        ];
      };

      packages.${system} = {
        claudevm = pkgs.callPackage ./nix/claudevm.nix {
          guest = self.nixosConfigurations.claudevm.config;
        };
        default = self.packages.${system}.claudevm;
      };

      checks.${system} = {
        inherit (self.packages.${system}) claudevm;
      };
    };
}

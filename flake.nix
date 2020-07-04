{
  description =
    "Modules to help you handle persistent state on systems with ephemeral root storage.";

  outputs = { ... }: {
    nixosModules = {
      home-manager-persistence = import ./home-manager.nix;
      nixos-persistence = import ./nixos.nix;
    };
  };
}

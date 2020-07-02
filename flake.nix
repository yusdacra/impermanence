{
  description =
    "Modules to help you handle persistent state on systems with ephemeral root storage.";

  outputs = { ... }: {
    nixosModules = {
      home-manager = import ./home-manager.nix;
      nixos = import ./nixos.nix;
    };
  };
}

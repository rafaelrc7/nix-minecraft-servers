{
  description = "Flexible Minecraft server NixOS module. Mixing declarative and imperative setups.";

  outputs = { self }: {
    nixosModules.nix-minecraft-servers = import ./module.nix;
    nixosModules.default = self.nixosModules.nix-minecraft-servers;
  };
}

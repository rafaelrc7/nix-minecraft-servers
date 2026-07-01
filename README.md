# nix-minecraft-servers

A NixOS module for managing Minecraft servers with a mix of declarative system configuration and imperative server data.

The module provides a reusable `minecraft-server@<name>` systemd template with per-server declarative overrides.

## Installation

Add this flake as an input:

```nix
{
  inputs.nix-minecraft-servers.url = "github:rafaelrc7/nix-minecraft-servers";

  outputs = { nixpkgs, nix-minecraft-servers, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      ...
      modules = [
        ...
        nix-minecraft-servers.nixosModules.default
      ];
    };
  };
}
```

## Basic Usage

```nix
{
  services.nix-minecraft-servers = {
    enable = true;

    servers.survival = {
      enable = true;
      eula = true;
      openFirewall = true;
    };
  };
}
```

By default, this expects the server jar at:

```text
/srv/minecraft/survival/server.jar
```

The server working directory is created automatically.

Start and stop the server with:

```sh
sudo systemctl start minecraft-server@survival
sudo systemctl stop minecraft-server@survival
```

### `server` option

The `services.nix-minecraft-servers.servers.\<name\>.server` option accepts a `string`, `path` or `derivation`.

- `string`: Used to point to a mutable jar file in the working directory of the server to be used.
- `path`: Used to point to a jar file that will be copied to the nix store and used for the server.
- `derivation`: Used to pass a package that contains an executable file for a minecraft server.

```nix
{
  services.nix-minecraft-servers.servers.survival = {
    enable = true;
    server = ./paper.jar;
  };

  services.nix-minecraft-servers.servers.paper = {
    enable = true;
    server = pkgs.papermc;
  };

  services.nix-minecraft-servers.servers.forge = {
    enable = true;
    server = "server.jar";
  };
}
```

### Java Versions

Set a default Java package globally:

```nix
{
  services.nix-minecraft-servers = {
    enable = true;
    javaPackage = pkgs.jdk21;
  };
}
```

Set Java package per server:

```nix
{
  services.nix-minecraft-servers.servers.old-forge = {
    enable = true;
    javaPackage = pkgs.jdk8;
    jvmOpts = [ ];
  };
}
```

Older Java versions may not support the default JVM flags, so set `jvmOpts = [ ];` or provide compatible flags.

### Environment Files

Each server loads this file if it exists:

```text
/srv/minecraft/<server>/.env
```

You can use it to override runtime values:

```env
JAR_NAME=server.jar
MEM=6G
JVM_OPTS=-XX:+UseG1GC
```

You can also set a custom environment file:

```nix
{
  services.nix-minecraft-servers.servers.survival = {
    enable = true;
    environmentFile = ./mc.env;
  };
}
```

### Firewall

Open the configured TCP port for a server:

```nix
{
  services.nix-minecraft-servers.servers.survival = {
    enable = true;
    openFirewall = true;
    port = 25565;
  };
}
```

The `port` option only controls the firewall. It does not write `server.properties`.

### EULA

Set `eula = true` to create an `eula.txt` symlink for that server:

```nix
{
  services.nix-minecraft-servers.servers.survival = {
    enable = true;
    eula = true;
  };
}
```

By setting this option, you confirm that you have read and accepted the [Minecraft EULA](https://aka.ms/MinecraftEULA):

## Server Data

You can access the server data and install plugins, modify config files, etc. In the server directory, by default:

```text
/srv/minecraft/<server>
```

## Sudo Rules

Optionally allow members of the minecraft group to manage related systemd units without a password:

```nix
{
  services.nix-minecraft-servers.sudoRules = true;
}
```

This allows commands such as:

```sh
systemctl start minecraft-server@survival
systemctl stop minecraft-server@survival
systemctl restart minecraft-server@survival
```

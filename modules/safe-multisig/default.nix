# Safe multisig stack, top-level NixOS module.
#
# Imported via `nixosModules.safe-multisig` from this flake's outputs. All
# per-deploy values are pulled from `config.safeMultisig.*`. See
# `options.nix` for the option surface; set values in your consumer flake.
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./options.nix
    ./disko.nix
    ./safe-stack.nix
    ./nginx.nix
    ./ui.nix
  ];

  assertions = [
    {
      assertion = lib.hasAttr config.safeMultisig.primaryChain config.safeMultisig.chains;
      message = ''
        safeMultisig.primaryChain ("${config.safeMultisig.primaryChain}") must be a key in safeMultisig.chains.
        Available chains: ${lib.concatStringsSep ", " (lib.attrNames config.safeMultisig.chains)}.
      '';
    }
  ];

  system.stateVersion = "25.05";
  nixpkgs.hostPlatform = "x86_64-linux";

  # Disko's EF02 partition wires GRUB onto `safeMultisig.bootDevice` automatically.
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  networking.hostName = config.safeMultisig.hostName;
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = config.safeMultisig.sshAuthorizedKeys;

  time.timeZone = config.safeMultisig.timeZone;

  # Docker (vs podman). Upstream safe-infrastructure compose syntax targets
  # the Docker CLI; running it under podman-compose hits compatibility edges.
  virtualisation.docker.enable = true;
}

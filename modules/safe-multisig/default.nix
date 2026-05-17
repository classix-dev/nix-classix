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

  # Disk layout and bootloader live in the platform module (see
  # `modules/platforms/<provider>/`). Provider modules own disko +
  # boot.loader because device naming and partition schemes differ
  # per cloud (DO is /dev/vda BIOS; Hetzner Robot is multi-disk; AWS
  # EC2 has NVMe). The safe-multisig module is platform-agnostic.

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

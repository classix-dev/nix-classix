# DigitalOcean droplet bootstrap. Cloud-init datasource, disko layout,
# bootloader, and the `lib.mkForce` overrides needed because nixpkgs'
# `digital-ocean-config.nix` pins fileSystems and grub.devices in ways
# that collide with our disko GPT layout.
#
# Consumer flake imports `nixosModules.platforms.digital-ocean` alongside
# `disko.nixosModules.disko` and the app-stack module of choice.
{ lib, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    "${modulesPath}/virtualisation/digital-ocean-config.nix"
  ];

  # `digital-ocean-config.nix` pins root-fs by label and grub to /dev/vda
  # via the upstream labels; both collide with our disko GPT layout.
  # Force-override so disko wins.
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-partlabel/disk-main-root";
    fsType = "ext4";
  };

  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    devices = lib.mkForce [ "/dev/vda" ];
  };

  # DO assigns the public IP via cloud-init metadata, NOT DHCP. Without
  # this datasource, sshd is up but no IPv4 lands and all ports time out.
  networking.useDHCP = lib.mkForce false;
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings.datasource_list = [
      "ConfigDrive"
      "DigitalOcean"
    ];
  };

  # Single-disk BIOS layout on /dev/vda. EF02 partition gets grub
  # automatically (disko wires it into boot.loader.grub.devices via
  # the partition's hardware ID match).
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # GRUB BIOS boot partition
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}

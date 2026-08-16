# Hetzner Cloud (CX/CPX x86) bootstrap. Single virtio disk, BIOS boot
# with a GRUB that also installs the removable-path EFI fallback, so
# the same layout boots regardless of which firmware mode the instance
# gets. IPv4 via DHCP, IPv6 static (Hetzner Cloud routes a /64 but
# announces no RA, so v6 has to be configured explicitly or skipped).
#
# Patterns from srvos `hardware-hetzner-cloud` and the LGUG2Z
# nixos-hetzner-cloud-starter, trimmed to what a disko-provisioned
# box needs. ARM (CAX) instances boot UEFI-only and are not covered.
#
# Detach Hetzner Volumes before running nixos-anywhere. Both the local
# disk and volumes are SCSI, and in the kexec installer a volume can
# enumerate as /dev/sda, which hands it the whole install (the hq
# deploy learned this the hard way). Attach volumes only once the box
# is booted into NixOS from its local disk.
{
  config,
  lib,
  modulesPath,
  ...
}:
let
  cfg = config.platformHetzner;
in
{
  imports = [
    "${modulesPath}/installer/scan/not-detected.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
    ./options.nix
  ];

  # Hetzner Cloud's console password-reset needs the guest agent.
  services.qemuGuest.enable = lib.mkDefault true;

  boot.loader.grub = {
    enable = true;
    # disko adds every disk carrying an EF02 partition to
    # `boot.loader.grub.devices`; no explicit list needed.
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-uplink" = {
    matchConfig.Name = lib.mkDefault "en* eth0";
    networkConfig = {
      DHCP = "ipv4";
      IPv6AcceptRA = "no";
    }
    // lib.optionalAttrs (cfg.ipv6Address != null) {
      Address = cfg.ipv6Address;
      Gateway = "fe80::1";
    };
  };

  # BIOS-boot stub + ESP + everything-else-root on the single virtio
  # disk. The ESP is dead weight while the instance boots BIOS, but at
  # 500M it is cheap insurance for the efiInstallAsRemovable path.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # GRUB BIOS boot partition
        };
        esp = {
          size = "500M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
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

# Hetzner dedicated (AX/EX line) bootstrap. Two NVMe drives in mdadm
# RAID, GRUB installed BIOS-and-removable-EFI so the box boots
# whichever firmware mode the model ships (several AX generations
# refuse to persist custom EFI boot entries; the removable fallback
# path sidesteps that, per phlip9's and CodeWitchBella's writeups).
# IPv4 via DHCP, IPv6 static, both over systemd-networkd. Networking
# follows srvos `hardware-hetzner-online`.
#
# Provisioning: boot the box into the Robot rescue system, then
# `nixos-anywhere --flake .#<key> root@<ip>`. If kexec fails in the
# rescue environment (reported on some models), installimage a
# throwaway Debian first and run nixos-anywhere against that. Watch
# via the free KVM console if anything looks stuck.
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
    ./options.nix
  ];

  options.platformHetzner.dedicated = {
    disks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/dev/nvme0n1"
        "/dev/nvme1n1"
      ];
      description = "The two NVMe devices to partition.";
    };

    raidLevel = lib.mkOption {
      type = lib.types.enum [
        0
        1
      ];
      default = 1;
      description = ''
        mdadm level for the root array. 1 (mirror) survives a disk
        failure at half the capacity; 0 (stripe) doubles capacity for
        data that is cheap to re-create. A chain database is
        re-syncable, so 0 is a legitimate choice when the node needs
        the space more than the uptime.
      '';
    };

    swapSize = lib.mkOption {
      type = lib.types.str;
      default = "8G";
      description = "Swap partition size per disk (both disks get one).";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.ipv6Address != null;
        message = "platformHetzner.ipv6Address must be set on dedicated boxes (find it in Robot; Hetzner sends no RAs).";
      }
    ];

    boot.initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "sd_mod"
      "nvme"
    ];
    boot.kernelModules = [ "kvm-amd" ];
    boot.swraid.enable = true;

    boot.loader.grub = {
      enable = true;
      # disko adds both EF02-carrying disks to grub.devices, so GRUB
      # lands in the MBR gap of each drive and the box still boots
      # after losing either one (the ESPs are mirrored below).
      efiSupport = true;
      efiInstallAsRemovable = true;
    };

    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.timeServers = [
      "ntp1.hetzner.de"
      "ntp2.hetzner.com"
      "ntp3.hetzner.de"
    ];

    systemd.network.networks."10-uplink" = {
      matchConfig.Name = lib.mkDefault "en* eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = "no";
        Address = cfg.ipv6Address;
        Gateway = "fe80::1";
      };
    };

    disko.devices =
      let
        mkDisk = _idx: device: {
          type = "disk";
          inherit device;
          content = {
            type = "gpt";
            partitions = {
              boot = {
                size = "1M";
                type = "EF02"; # GRUB BIOS boot partition
              };
              esp = {
                size = "1G";
                type = "EF00";
                content = {
                  type = "mdraid";
                  name = "boot";
                };
              };
              swap = {
                size = cfg.dedicated.swapSize;
                content = {
                  type = "swap";
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "mdraid";
                  name = "root";
                };
              };
            };
          };
        };
      in
      {
        disk = lib.listToAttrs (
          lib.imap0 (
            idx: device: lib.nameValuePair "nvme${toString idx}" (mkDisk idx device)
          ) cfg.dedicated.disks
        );

        mdadm = {
          # metadata 1.0 puts the md superblock at the END of the
          # partition, so firmware that knows nothing about mdadm can
          # read either half as a plain FAT ESP and boot from it.
          boot = {
            type = "mdadm";
            level = 1;
            metadata = "1.0";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };

          root = {
            type = "mdadm";
            level = cfg.dedicated.raidLevel;
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

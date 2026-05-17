# Single-disk BIOS layout. Disk path comes from `safeMultisig.bootDevice`
# (typically `/dev/vda`, which fits most cloud VMs).
{ config, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = config.safeMultisig.bootDevice;
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

# Options shared by the Hetzner platform modules (cloud.nix and
# dedicated.nix). Split out so both variants read the same namespace.
{ lib, ... }:
{
  options.platformHetzner = {
    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2a01:4f9:4b:4084::1/64";
      description = ''
        Static IPv6 address with prefix length. Hetzner announces no
        router advertisements, so v6 only works if set explicitly
        (gateway is always fe80::1). Null skips IPv6 entirely, which
        is fine on cloud (v4 comes via DHCP) but leaves a dedicated
        box v4-only.
      '';
    };
  };
}

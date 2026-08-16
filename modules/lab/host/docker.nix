{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.lab.network = {
    dockerSubnet = mkOption {
      type = types.str;
      default = "172.19.0.0/16";
      description = ''
        Subnet for the lab's docker bridge network. It must not overlap any
        other docker network on the machine, including another lab's, because
        a docker network owns its subnet exclusively. `cata lab up` checks
        this before it starts anything and suggests a free range.

        The DNS server address and the plan's gateway are both derived from
        it, so it is load-bearing rather than cosmetic.
      '';
    };

    configureHostRoute = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether `cata lab up` routes the lab's subnet through the Colima VM
        on macOS. This needs `sudo` for `route`, `sysctl` and `iptables`, and
        without it pods are unreachable from the host on a Mac.

        It is a no-op on Linux, where the bridge is already on the host.

        Unlike `lab.dns.configureHost` and `lab.trust.installIntoHostStore`,
        which are conveniences and default off, this defaults on because a
        macOS lab does not work without it. Turn it off when you have routed
        the subnet yourself, or when you only reach the lab through the
        published ingress port, which `cata lab verify` already does.
      '';
    };
  };
}

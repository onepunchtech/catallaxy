# lib/network.nix
#
# Network utility functions for IP address and CIDR manipulation.

{ lib }:

{
  # Parse an IPv4 address string into a list of integers
  # "10.96.0.1" -> [10 96 0 1]
  parseIPv4 = ip: map lib.strings.toInt (lib.splitString "." ip);

  # Convert a list of integers back to an IPv4 string
  # [10 96 0 1] -> "10.96.0.1"
  formatIPv4 = octets: lib.concatStringsSep "." (map toString octets);

  # Get the network address from a CIDR
  # "10.96.0.0/12" -> "10.96.0.0"
  cidrToNetwork = cidr: lib.head (lib.splitString "/" cidr);

  # Get the prefix length from a CIDR
  # "10.96.0.0/12" -> 12
  cidrToPrefixLen = cidr: lib.strings.toInt (lib.last (lib.splitString "/" cidr));

  # Compute the first usable IP in a CIDR (network + 1)
  # This is typically the Kubernetes API service IP for service CIDRs
  # "10.96.0.0/12" -> "10.96.0.1"
  # "192.168.0.0/16" -> "192.168.0.1"
  cidrFirstIP =
    cidr:
    let
      network = lib.head (lib.splitString "/" cidr);
      octets = map lib.strings.toInt (lib.splitString "." network);
      # Add 1 to the last octet (assumes network address ends in .0)
      firstIP = lib.init octets ++ [ ((lib.last octets) + 1) ];
    in
    lib.concatStringsSep "." (map toString firstIP);
}

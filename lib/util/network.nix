{ lib }:

let
  parseIPv4 = ip: map lib.strings.toInt (lib.splitString "." ip);

  ipv4ToInt =
    ip:
    let
      octets = parseIPv4 ip;
    in
    (lib.elemAt octets 0) * 16777216
    + (lib.elemAt octets 1) * 65536
    + (lib.elemAt octets 2) * 256
    + (lib.elemAt octets 3);

  cidrToNetwork = cidr: lib.head (lib.splitString "/" cidr);
  cidrToPrefixLen = cidr: lib.strings.toInt (lib.last (lib.splitString "/" cidr));

  pow2 = n: if n == 0 then 1 else 2 * pow2 (n - 1);
  prefixToMask = prefix: (pow2 32) - (pow2 (32 - prefix));

  networkBase = ipInt: prefix: builtins.bitAnd ipInt (prefixToMask prefix);
in

rec {
  inherit
    parseIPv4
    cidrToNetwork
    cidrToPrefixLen
    ipv4ToInt
    ;

  formatIPv4 = octets: lib.concatStringsSep "." (map toString octets);

  cidrFirstIP =
    cidr:
    let
      network = cidrToNetwork cidr;
      octets = parseIPv4 network;
      firstIP = lib.init octets ++ [ ((lib.last octets) + 1) ];
    in
    formatIPv4 firstIP;

  ipInCidr =
    ip: cidr:
    let
      prefix = cidrToPrefixLen cidr;
      cidrIpInt = ipv4ToInt (cidrToNetwork cidr);
      ipInt = ipv4ToInt ip;
    in
    networkBase ipInt prefix == networkBase cidrIpInt prefix;

  cidrsOverlap =
    a: b:
    let
      aStart = ipv4ToInt (cidrToNetwork a);
      bStart = ipv4ToInt (cidrToNetwork b);
      aPrefix = cidrToPrefixLen a;
      bPrefix = cidrToPrefixLen b;
    in
    (networkBase aStart bPrefix == networkBase bStart bPrefix)
    || (networkBase bStart aPrefix == networkBase aStart aPrefix);
}

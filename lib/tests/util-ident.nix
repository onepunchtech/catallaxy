{ lib }:

let
  ident = import ../util/ident.nix { inherit lib; };
in
lib.runTests {

  # Terraform identifiers: a letter or underscore, then letters, digits,
  # underscores and dashes.
  testTerraformAcceptsALetterStart = {
    expr = ident.isTerraformName "mgmt_cluster";
    expected = true;
  };

  testTerraformAcceptsAnUnderscoreStart = {
    expr = ident.isTerraformName "_private";
    expected = true;
  };

  testTerraformAcceptsDashesAndDigits = {
    expr = ident.isTerraformName "core-1_a";
    expected = true;
  };

  testTerraformRefusesADigitStart = {
    expr = ident.isTerraformName "1cluster";
    expected = false;
  };

  testTerraformRefusesADashStart = {
    expr = ident.isTerraformName "-cluster";
    expected = false;
  };

  testTerraformRefusesADot = {
    expr = ident.isTerraformName "mesh.local";
    expected = false;
  };

  testTerraformRefusesEmpty = {
    expr = ident.isTerraformName "";
    expected = false;
  };

  testTerraformRefusesWhitespace = {
    expr = ident.isTerraformName "two words";
    expected = false;
  };

  # A single character is a whole name.
  testTerraformAcceptsOneLetter = {
    expr = ident.isTerraformName "a";
    expected = true;
  };

  # Field managers: alphanumeric, then alphanumerics, dots, dashes,
  # underscores. kaniop registers per-CRD names with dots in them.
  testFieldManagerAcceptsADottedName = {
    expr = ident.isFieldManagerName "kanidmoauth2clients.kaniop.rs";
    expected = true;
  };

  testFieldManagerAcceptsADigitStart = {
    expr = ident.isFieldManagerName "2048-operator";
    expected = true;
  };

  testFieldManagerRefusesADotStart = {
    expr = ident.isFieldManagerName ".hidden";
    expected = false;
  };

  # The failure this check exists for: a YAML list pasted in verbatim.
  testFieldManagerRefusesANewline = {
    expr = ident.isFieldManagerName "- one\n- two";
    expected = false;
  };

  testFieldManagerRefusesEmpty = {
    expr = ident.isFieldManagerName "";
    expected = false;
  };

  # FQDNs, lowercase RFC 1123, two labels minimum.
  testFqdnAcceptsTwoLabels = {
    expr = ident.isFqdn "vpn.example.com";
    expected = true;
  };

  testFqdnAcceptsAnInternalDash = {
    expr = ident.isFqdn "signal-nb.example.com";
    expected = true;
  };

  testFqdnAcceptsSingleCharacterLabels = {
    expr = ident.isFqdn "a.b";
    expected = true;
  };

  testFqdnRefusesABareHostname = {
    expr = ident.isFqdn "localhost";
    expected = false;
  };

  testFqdnRefusesEmpty = {
    expr = ident.isFqdn "";
    expected = false;
  };

  testFqdnRefusesATrailingDot = {
    expr = ident.isFqdn "example.com.";
    expected = false;
  };

  testFqdnRefusesALeadingDot = {
    expr = ident.isFqdn ".example.com";
    expected = false;
  };

  testFqdnRefusesAnEmptyLabel = {
    expr = ident.isFqdn "a..b";
    expected = false;
  };

  testFqdnRefusesALabelEndingInADash = {
    expr = ident.isFqdn "bad-.example.com";
    expected = false;
  };

  testFqdnRefusesUppercase = {
    expr = ident.isFqdn "VPN.example.com";
    expected = false;
  };

  testFqdnRefusesAScheme = {
    expr = ident.isFqdn "https://vpn.example.com";
    expected = false;
  };

  testFqdnRefusesALabelOver63Characters = {
    expr = ident.isFqdn "${lib.concatStrings (lib.genList (_: "a") 64)}.com";
    expected = false;
  };

  testFqdnAcceptsALabelOfExactly63Characters = {
    expr = ident.isFqdn "${lib.concatStrings (lib.genList (_: "a") 63)}.com";
    expected = true;
  };

  testTypesRefuseNonStrings = {
    expr = [
      (ident.types.fqdn.check 3)
      (ident.types.terraformName.check null)
      (ident.types.fieldManagerName.check [ "a" ])
    ];
    expected = [
      false
      false
      false
    ];
  };
}

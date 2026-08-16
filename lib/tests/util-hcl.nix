{ lib }:

let
  hcl = import ../util/hcl.nix { inherit lib; };
in
lib.runTests {

  # The whole reason this exists. The renderer it replaced put every value
  # through `toString` inside quotes, so an int arrived as a string and a bool
  # arrived as "1" or "".
  testAnIntIsBare = {
    expr = hcl.value 8200;
    expected = "8200";
  };

  testABoolIsTrueOrFalse = {
    expr = [
      (hcl.value true)
      (hcl.value false)
    ];
    expected = [
      "true"
      "false"
    ];
  };

  testAStringIsQuoted = {
    expr = hcl.value "us-east-1";
    expected = ''"us-east-1"'';
  };

  # A path or a credential can carry either, and an unescaped one ends the
  # string early and leaves OpenBao with unparseable config.
  testQuotesAndBackslashesAreEscaped = {
    expr = hcl.value ''a"b\c'';
    expected = ''"a\"b\\c"'';
  };

  testAListKeepsItsElementTypes = {
    expr = hcl.value [
      "a"
      1
      true
    ];
    expected = ''["a", 1, true]'';
  };

  testAnAttrsetBecomesANestedBlock = {
    expr = hcl.body "" {
      retry_join = {
        leader_api_addr = "http://a:8200";
        tls_skip_verify = true;
      };
    };
    expected = ''
      retry_join {
        leader_api_addr = "http://a:8200"
        tls_skip_verify = true
      }
    '';
  };

  testALabelledBlock = {
    expr = hcl.block "seal" "awskms" {
      region = "us-east-1";
      kms_key_id = "alias/unseal";
    };
    expected = ''
      seal "awskms" {
        kms_key_id = "alias/unseal"
        region = "us-east-1"
      }
    '';
  };

  # Anything the renderer cannot express is an eval error rather than a
  # silently wrong config file.
  testAValueWithNoHclFormIsRefused = {
    expr = (builtins.tryEval (hcl.value null)).success;
    expected = false;
  };
}

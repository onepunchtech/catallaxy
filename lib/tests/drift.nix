{ lib }:

let
  drift = import ../eval/drift.nix { inherit lib; };
  inherit (drift) escapePointer toArgocdResourceCustomizations toArgocdIgnoreDifferences;

  mkEntry =
    attrs:
    {
      reason = "fixture";
      group = "example.io";
      kinds = [ "Widget" ];
      managedBy = [ ];
      fields = [ ];
      name = null;
      namespace = null;
      shareable = true;
    }
    // attrs;
in
lib.runTests {

  testPointerSimple = {
    expr = escapePointer "spec.skipImmediately";
    expected = "/spec/skipImmediately";
  };

  testPointerQuotedSegment = {
    expr = escapePointer ''metadata.annotations."reloader.stakater.com/last-reloaded-from"'';
    expected = "/metadata/annotations/reloader.stakater.com~1last-reloaded-from";
  };

  testPointerTildeBeforeSlash = {
    expr = escapePointer ''spec."a~b/c"'';
    expected = "/spec/a~0b~1c";
  };

  testManagersUnionAggregate = {
    expr = toArgocdResourceCustomizations {
      entries = [ (mkEntry { managedBy = [ "widget-operator" ]; }) ];
      aggregateManagers = [
        "kapp"
        "helm"
      ];
    };
    expected = {
      "resource.customizations.ignoreDifferences.example.io_Widget" =
        "managedFieldsManagers:\n- helm\n- kapp\n- widget-operator\n";
    };
  };

  testKindsFanOut = {
    expr = lib.attrNames (toArgocdResourceCustomizations {
      entries = [
        (mkEntry {
          kinds = [
            "Group"
            "SetupKey"
          ];
          managedBy = [ "netbird-operator" ];
        })
      ];
    });
    expected = [
      "resource.customizations.ignoreDifferences.example.io_Group"
      "resource.customizations.ignoreDifferences.example.io_SetupKey"
    ];
  };

  testSameKindMerges = {
    expr = toArgocdResourceCustomizations {
      entries = [
        (mkEntry { managedBy = [ "b-operator" ]; })
        (mkEntry { managedBy = [ "a-operator" ]; })
      ];
    };
    expected = {
      "resource.customizations.ignoreDifferences.example.io_Widget" =
        "managedFieldsManagers:\n- a-operator\n- b-operator\n";
    };
  };

  testManagerDedup = {
    expr = toArgocdResourceCustomizations {
      entries = [ (mkEntry { managedBy = [ "dup" ]; }) ];
      aggregateManagers = [
        "dup"
        "dup"
      ];
    };
    expected = {
      "resource.customizations.ignoreDifferences.example.io_Widget" = "managedFieldsManagers:\n- dup\n";
    };
  };

  testFieldsLowerToPointers = {
    expr = toArgocdResourceCustomizations {
      entries = [ (mkEntry { fields = [ "spec.skipImmediately" ]; }) ];
    };
    expected = {
      "resource.customizations.ignoreDifferences.example.io_Widget" =
        "jsonPointers:\n- /spec/skipImmediately\n";
    };
  };

  testEmptyInputEmptyOutput = {
    expr = toArgocdResourceCustomizations {
      entries = [ ];
      aggregateManagers = [ "kapp" ];
    };
    expected = { };
  };

  testDeclarationWithNothingIsDropped = {
    expr = toArgocdResourceCustomizations {
      entries = [ (mkEntry { }) ];
    };
    expected = { };
  };

  testBundleScopeCarriesNameAndNamespace = {
    expr = toArgocdIgnoreDifferences [
      (mkEntry {
        managedBy = [ "widget-operator" ];
        name = "only-this";
        namespace = "ns";
      })
    ];
    expected = [
      {
        group = "example.io";
        kind = "Widget";
        managedFieldsManagers = [ "widget-operator" ];
        name = "only-this";
        namespace = "ns";
      }
    ];
  };

  testBundleScopeDropsEmptyDeclarations = {
    expr = toArgocdIgnoreDifferences [ (mkEntry { }) ];
    expected = [ ];
  };
}

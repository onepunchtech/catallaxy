{ lib }:

let
  fields = import ../util/k8s-fields.nix { inherit lib; };

  untypedRoute = {
    kind = "HTTPRoute";
    spec.rules = [ { backendRefs = [ { port = 80; } ]; } ];
  };

  typedRoute = {
    kind = "HTTPRoute";
    spec = {
      hostnames = null;
      rules = [
        {
          backendRefs = [
            {
              namespace = null;
              port = 80;
            }
          ];
          matches = null;
        }
      ];
    };
  };
in
lib.runTests {
  testAFieldTheResourceNeverMentions = {
    expr = fields.listOrEmpty [ "spec" "hostnames" ] untypedRoute;
    expected = [ ];
  };

  testAFieldATypedResourceLeftAtItsNullDefault = {
    expr = fields.listOrEmpty [ "spec" "hostnames" ] typedRoute;
    expected = [ ];
  };

  testTheSamePathReadsBothShapesTheSameWay = {
    expr = [
      (fields.listOrEmpty [ "spec" "rules" ] untypedRoute)
      (fields.listOrEmpty [ "spec" "rules" ] typedRoute)
    ];
    expected = [
      untypedRoute.spec.rules
      typedRoute.spec.rules
    ];
  };

  testAPathThatRunsThroughANullStopsThereRatherThanThrowing = {
    expr = fields.listOrEmpty [ "spec" "rules" ] { spec = null; };
    expected = [ ];
  };

  testAPathThroughSomethingThatIsNotAnAttrsetStopsThere = {
    expr = fields.valueAt [ "spec" "rules" ] { spec = "not-a-set"; };
    expected = null;
  };

  testAFallbackIsUsedForNullNotJustForAbsent = {
    expr = [
      (fields.valueOr [ "namespace" ] "app" { namespace = null; })
      (fields.valueOr [ "namespace" ] "app" { })
      (fields.valueOr [ "namespace" ] "app" { namespace = "other"; })
    ];
    expected = [
      "app"
      "app"
      "other"
    ];
  };

  testAnEmptyPathIsTheResourceItself = {
    expr = fields.valueAt [ ] untypedRoute;
    expected = untypedRoute;
  };

  testAFalseValueIsNotTreatedAsMissing = {
    expr = fields.valueOr [ "optional" ] true { optional = false; };
    expected = false;
  };
}

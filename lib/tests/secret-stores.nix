{ lib }:

let
  # Evaluate just the secrets module, with the lab options it depends on
  # stubbed, so these tests are about store direction and nothing else.
  evalStores =
    stores:
    (lib.evalModules {
      modules = [
        ../../modules/lab/secrets
        {
          options.lab.assertions = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
          };
          options.lab.name = lib.mkOption {
            type = lib.types.str;
            default = "test-lab";
          };
          config.lab.secrets.stores = stores;
        }
      ];
    }).config.lab.secrets.stores;

  directionOf = backend: (evalStores { s.backend = backend; }).s.direction;

  check =
    name: expected: actual:
    lib.optional (expected != actual) {
      inherit name expected actual;
    };
in
lib.concatLists [

  (check "sops is authored, because a cluster cannot commit to your repository" "authored" (
    directionOf "sops"
  ))

  (check "env is authored, for the same reason: the value comes from outside" "authored" (
    directionOf "env"
  ))

  (check "vault is a runtime store, so a cluster can publish into it" "runtime" (directionOf "vault"))

  (check "external is a runtime store" "runtime" (directionOf "external"))

  (check "the default backend is sops, and so authored" "authored"
    (evalStores { s = { }; }).s.direction
  )

  (check "direction is derived per store, not per lab" [ "authored" "runtime" ] (
    let
      stores = evalStores {
        a.backend = "sops";
        b.backend = "vault";
      };
    in
    [
      stores.a.direction
      stores.b.direction
    ]
  ))
]

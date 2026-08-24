{ lib, pkgs }:

let
  providers = import ../../infra/providers.nix { inherit lib; };

  # A stand-in for `pkgs.opentofu.plugins`, so the test says what it is about
  # rather than depending on what nixpkgs happens to package today.
  plugins = {
    hashicorp_local = {
      version = "2.9.0";
      meta.homepage = "https://registry.terraform.io/providers/hashicorp/local";
    };
    hashicorp_aws = {
      version = "6.54.0";
      meta.homepage = "https://registry.terraform.io/providers/hashicorp/aws";
    };
    digitalocean_digitalocean = {
      version = "2.95.0";
      meta.homepage = "https://registry.terraform.io/providers/digitalocean/digitalocean";
    };
    argocd = {
      version = "1.0.0";
      meta.homepage = "https://registry.terraform.io/providers/argoproj-labs/argocd";
    };
    oboukili_argocd = {
      version = "6.0.0";
      meta.homepage = "https://registry.terraform.io/providers/oboukili/argocd";
    };
  };

  resolve = args: providers.resolve ({ inherit plugins; } // args);

  refused =
    expr: text:
    let
      r = builtins.tryEval (builtins.deepSeq expr expr);
    in
    !r.success || (builtins.isString r.value && lib.hasInfix text r.value);
in
lib.runTests {
  testASourceIsReadFromTheRegistryAddress = {
    expr = resolve { provider = "aws"; };
    expected = {
      attr = "hashicorp_aws";
      source = "hashicorp/aws";
      version = "6.54.0";
    };
  };

  # The vendor is not always `hashicorp`, which is why the address is read
  # rather than assembled from the provider name.
  testANonHashicorpVendorResolves = {
    expr = (resolve { provider = "digitalocean"; }).source;
    expected = "digitalocean/digitalocean";
  };

  # The version is what will actually run, so the rendered file describes the
  # binary rather than a hope about it.
  testTheVersionIsThePackagesVersion = {
    expr = (resolve { provider = "local"; }).version;
    expected = "2.9.0";
  };

  testAnUnpackagedProviderIsRefused = {
    expr = refused (resolve { provider = "nonesuch"; }) "not packaged in nixpkgs";
    expected = true;
  };

  # Three of the packaged providers share a short name. Picking one by
  # evaluation order would hand a lab someone else's implementation.
  testAnAmbiguousNameIsRefused = {
    expr = refused (resolve { provider = "argocd"; }) "is ambiguous";
    expected = true;
  };

  testAnExplicitSourceSettlesAmbiguity = {
    expr =
      (resolve {
        provider = "argocd";
        source = "oboukili/argocd";
      }).version;
    expected = "6.0.0";
  };

  testAnExplicitSourceThatIsNotPackagedIsRefused = {
    expr = refused (resolve {
      provider = "argocd";
      source = "someone/argocd";
    }) "is not packaged in nixpkgs";
    expected = true;
  };
}

{ lib, pkgs }:

let
  refs = import ../../infra/ref.nix { inherit lib; };
  check = import ../../infra/check.nix { inherit lib; };
  render = import ../../render/infra-terraform.nix { inherit lib; };

  resource =
    {
      stack ? "default",
      type ? "aws_s3_bucket",
      inputs ? { },
      outputs ? [ ],
      provider ? "aws",
      instance ? "main",
    }:
    {
      inherit
        stack
        type
        inputs
        outputs
        provider
        instance
        ;
      publish = { };
    };

  bucketAndUser = {
    bucket = resource {
      inputs.bucket = "lab-backups";
      outputs = [ "arn" ];
    };
    policy = resource {
      type = "aws_iam_policy";
      inputs.resource = refs.ref "bucket" "arn";
    };
  };

  errorsFor = resources: check.referenceErrors resources;

  quotes = messages: text: lib.any (m: lib.hasInfix text m) messages;
in
lib.runTests {
  testARefIsRecognised = {
    expr = refs.isRef (refs.ref "bucket" "arn");
    expected = true;
  };

  testAPlainAttrsetIsNotARef = {
    expr = refs.isRef {
      resource = "bucket";
      output = "arn";
    };
    expected = false;
  };

  # The reference resolves through the *target's* type, which is why a
  # reference to a resource that does not exist cannot be rendered at all
  # rather than merely rendering to something wrong.
  testARefResolvesThroughTheTargetsType = {
    expr = refs.resolveWith { resources = bucketAndUser; } (refs.ref "bucket" "arn");
    expected = "\${aws_s3_bucket.bucket.arn}";
  };

  testResolvingWalksNestedStructure = {
    expr = refs.resolveWith { resources = bucketAndUser; } {
      a = [ (refs.ref "bucket" "arn") ];
      b = "static";
    };
    expected = {
      a = [ "\${aws_s3_bucket.bucket.arn}" ];
      b = "static";
    };
  };

  testAValidGraphHasNoErrors = {
    expr = errorsFor bucketAndUser;
    expected = [ ];
  };

  testARefToAnUnknownResourceIsRefused = {
    expr = quotes (errorsFor {
      policy = resource {
        type = "aws_iam_policy";
        inputs.resource = refs.ref "typo" "arn";
      };
    }) "no resource\nnamed 'typo' is declared";
    expected = true;
  };

  # The output list is the interface. Inferring it would mean a typo reaches
  # the provider, which only answers after everything earlier in the plan has
  # already run.
  testARefToAnUndeclaredOutputIsRefused = {
    expr = quotes (errorsFor {
      bucket = resource { outputs = [ "arn" ]; };
      policy = resource {
        type = "aws_iam_policy";
        inputs.resource = refs.ref "bucket" "bucket_domain_name";
      };
    }) "does not declare as an output";
    expected = true;
  };

  # Across a stack boundary the target's attributes are not in scope, so the
  # reference reads the producer's state instead. The producer already emits
  # an output for every attribute it declares.
  testARefAcrossStacksReadsRemoteState = {
    expr = refs.resolveWith {
      resources = bucketAndUser;
      crossStack = {
        here = "other";
        stackOf = _: "cloud";
      };
    } (refs.ref "bucket" "arn");
    expected = "\${data.terraform_remote_state.cloud.outputs.bucket_arn}";
  };

  testARefInsideOneStackStaysAnInterpolation = {
    expr = refs.resolveWith {
      resources = bucketAndUser;
      crossStack = {
        here = "cloud";
        stackOf = _: "cloud";
      };
    } (refs.ref "bucket" "arn");
    expected = "\${aws_s3_bucket.bucket.arn}";
  };

  testARefInAManifestIsRefused = {
    expr = quotes (check.manifestRefErrors {
      app.resources.cm.data.arn = refs.ref "bucket" "arn";
    }) "cannot go in a Kubernetes resource";
    expected = true;
  };

  testAManifestWithNoRefsIsFine = {
    expr = check.manifestRefErrors { app.resources.cm.data.arn = "static"; };
    expected = [ ];
  };

  # The whole point of the renderer: what terraform reads is the resource
  # table keyed by type then by name, with references already interpolated.
  testTheRendererEmitsTerraformJson = {
    expr = render.stack {
      name = "cloud";
      stacks.cloud = {
        resources = bucketAndUser;
        backend.local = { };
        requiredProviders.aws = {
          source = "hashicorp/aws";
          version = "6.54.0";
        };
        providers.aws.main.region = "us-east-1";
      };
    };
    expected = {
      terraform = {
        backend.local = { };
        required_providers.aws = {
          source = "hashicorp/aws";
          version = "6.54.0";
        };
      };
      provider.aws.region = "us-east-1";
      resource = {
        aws_s3_bucket.bucket.bucket = "lab-backups";
        aws_iam_policy.policy.resource = "\${aws_s3_bucket.bucket.arn}";
      };
      output.bucket_arn.value = "\${aws_s3_bucket.bucket.arn}";
    };
  };

  # A published value goes to a secret store, so printing it in every plan
  # and apply log would defeat the point.
  # One stack, two configurations of one provider. Terraform takes a list
  # when there is more than one, and every one but the default carries an
  # alias. A resource on an aliased instance says which it uses.
  testProviderInstancesBecomeAliases = {
    expr =
      let
        rendered = render.stack {
          name = "cloud";
          stacks.cloud = {
            resources.bucket = resource {
              instance = "eu";
              inputs.bucket = "b";
            };
            backend.local = { };
            requiredProviders = { };
            providers.aws = {
              main.region = "us-east-1";
              eu.region = "eu-west-1";
            };
          };
        };
      in
      {
        blocks = rendered.provider.aws;
        tag = rendered.resource.aws_s3_bucket.bucket.provider;
      };
    expected = {
      blocks = [
        {
          alias = "eu";
          region = "eu-west-1";
        }
        { region = "us-east-1"; }
      ];
      tag = "aws.eu";
    };
  };

  testAPublishedOutputIsSensitive = {
    expr =
      (render.stack {
        name = "cloud";
        stacks.cloud = {
          resources = bucketAndUser;
          backend.local = { };
          requiredProviders = { };
          providers = { };
        };
        publishedOutputs = [ "bucket_arn" ];
      }).output.bucket_arn.sensitive;
    expected = true;
  };
}

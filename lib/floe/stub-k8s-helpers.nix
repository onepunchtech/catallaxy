{ lib }:

# The k8sHelpers a floe sees when it is evaluated on its own, outside a lab.
#
# These used to be hand-written fakes, which meant a floe test asserted on a
# rendering no lab ever produced, and adding a helper meant remembering to add
# a fake for it. The real helpers need nothing but `lib`, so a floe under test
# now renders exactly what it renders in a lab.
import ../k8s-helpers.nix { inherit lib; }

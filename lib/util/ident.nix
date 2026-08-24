{ lib }:

# Name grammars, as character sets rather than as patterns.
#
# Three places in the tree asked "is this name well formed?" with three
# character-class regexes: a Terraform identifier in `lib/infra/check.nix`, an
# SSA field-manager name in `modules/lab/cluster/drift.nix`, and an FQDN in
# the netbird floe. Each one restated an alphabet inline, so the alphabet was
# only ever visible as `[A-Za-z0-9._-]` at the point of use and could not be
# reused, tested or named.
#
# A character set is data. Membership in it is a lookup. That is the whole
# idea here: `allIn` walks the string and asks the set, and the grammars below
# are built by saying which set the first character comes from and which set
# the rest come from.

let
  charsOf = lib.stringToCharacters;
  setOf = s: lib.genAttrs (charsOf s) (_: true);

  lower = "abcdefghijklmnopqrstuvwxyz";
  upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  digit = "0123456789";

  has = set: c: set ? ${c};
  allIn = set: s: lib.all (has set) (charsOf s);

  # A name whose first character is drawn from one set and whose remaining
  # characters are drawn from another. Both Terraform identifiers and field
  # manager names are this shape; they differ only in the two sets.
  shaped =
    { first, rest }:
    s:
    let
      width = builtins.stringLength s;
    in
    builtins.isString s
    && width > 0
    && has first (builtins.substring 0 1 s)
    && allIn rest (builtins.substring 1 width s);

  # Terraform: a letter or underscore, then letters, digits, underscores and
  # dashes. Rendered resource and data-source names have to satisfy this or
  # the generated HCL is a parse error.
  isTerraformName = shaped {
    first = setOf (lower + upper + "_");
    rest = setOf (lower + upper + digit + "_-");
  };

  # Kubernetes SSA field managers: alphanumeric, then alphanumerics, dots,
  # dashes and underscores.
  isFieldManagerName = shaped {
    first = setOf (lower + upper + digit);
    rest = setOf (lower + upper + digit + "._-");
  };

  # One RFC 1123 label, lowercase: alphanumeric at both ends, dashes allowed
  # in between, at most 63 characters.
  labelAlnum = setOf (lower + digit);
  labelBody = setOf (lower + digit + "-");

  isDnsLabel =
    s:
    let
      width = builtins.stringLength s;
    in
    builtins.isString s
    && width >= 1
    && width <= 63
    && allIn labelBody s
    && has labelAlnum (builtins.substring 0 1 s)
    && has labelAlnum (builtins.substring (width - 1) 1 s);

  # Two or more labels joined by dots. A bare hostname is not an FQDN, which
  # is the point of the check at every call site.
  isFqdn =
    s:
    let
      labels = lib.splitString "." s;
    in
    builtins.isString s
    && builtins.stringLength s <= 253
    && builtins.length labels >= 2
    && lib.all isDnsLabel labels;

  typed =
    name: description: check:
    lib.types.addCheck lib.types.str check
    // {
      inherit name description;
    };

in
{
  inherit
    isTerraformName
    isFieldManagerName
    isDnsLabel
    isFqdn
    allIn
    setOf
    ;

  types = {
    terraformName =
      typed "terraformName"
        "Terraform identifier: a letter or underscore, then letters, digits, underscores and dashes"
        isTerraformName;

    fieldManagerName =
      typed "fieldManagerName"
        "Kubernetes field manager name: alphanumeric, then alphanumerics, dots, dashes and underscores"
        isFieldManagerName;

    fqdn =
      typed "fqdn" "fully qualified domain name: two or more lowercase RFC 1123 labels joined by dots"
        isFqdn;
  };
}

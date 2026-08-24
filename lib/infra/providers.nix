{ lib }:

let
  # nixpkgs names a provider package `<vendor>_<name>`, and its homepage is the
  # registry address. Reading the address rather than reassembling it from the
  # attribute means the source can never disagree with the package: they come
  # from the same expression.
  sourceOf =
    plugins: attr:
    let
      home = toString (plugins.${attr}.meta.homepage or "");
      parts = lib.splitString "/" home;
      tail = lib.sublist (lib.length parts - 2) 2 parts;
    in
    if lib.hasInfix "registry.terraform.io/providers/" home then
      lib.concatStringsSep "/" tail
    else
      lib.replaceStrings [ "_" ] [ "/" ] attr;

  candidatesFor =
    plugins: provider:
    lib.filter (attr: attr == provider || lib.hasSuffix "_${provider}" attr) (lib.attrNames plugins);
in
{
  inherit sourceOf candidatesFor;

  # What a resource's `provider` resolves to, given the packages this lab will
  # actually run.
  #
  # Derived rather than declared because a lab that writes the source and the
  # version by hand can write them wrong, and the first sign of that is a
  # failure inside `tofu init` talking about a registry.
  resolve =
    {
      plugins,
      provider,
      source ? null,
    }:
    let
      byExplicitSource = lib.filter (attr: sourceOf plugins attr == source) (lib.attrNames plugins);

      candidates = if source == null then candidatesFor plugins provider else byExplicitSource;

      attr = lib.head candidates;
    in
    if candidates == [ ] then
      throw ''
        ${
          if source == null then
            "provider '${provider}' is not packaged in nixpkgs"
          else
            "provider source '${source}' is not packaged in nixpkgs"
        }, so this lab cannot carry it.

        Providers are pinned rather than downloaded: a lab holds the exact
        binaries it was built against, so an apply is the same on every
        machine and needs no network to start. Nothing falls back to
        fetching, which is why this is refused here rather than failing at
        `tofu init`.

        Looked in `pkgs.opentofu.plugins` for ${
          if source == null then
            "an attribute named `${provider}` or `<vendor>_${provider}`"
          else
            "a package whose registry address is `${source}`"
        }.
      ''
    else if lib.length candidates > 1 then
      throw ''
        provider '${provider}' is ambiguous: nixpkgs packages ${
          lib.concatStringsSep " and " (map (a: "`${a}`") candidates)
        }.

        The short name alone does not say which vendor's provider you mean,
        and picking one by evaluation order would silently give a lab the
        wrong implementation.

        Say which, by giving the registry address:

        ${lib.concatMapStringsSep "\n" (
          a: "          requiredProviders.${provider}.source = \"${sourceOf plugins a}\";"
        ) candidates}
      ''
    else
      {
        inherit attr;
        source = sourceOf plugins attr;
        version = plugins.${attr}.version or null;
      };
}

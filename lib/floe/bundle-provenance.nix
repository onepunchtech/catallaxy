{ lib }:

let
  # `mkIf`, `mkMerge` and friends are ordinary attrsets carrying a `_type`, so
  # a module body can be rebuilt as the same tree of conditions with different
  # leaves. Rebuilding rather than collecting bundle names is what keeps a
  # bundle behind a false condition from being brought into existence by the
  # stamp: the stamp inherits the condition it was found under.
  overLeaves =
    f: v:
    if !(builtins.isAttrs v) then
      { }
    else if (v._type or null) == "if" then
      lib.mkIf v.condition (overLeaves f v.content)
    else if (v._type or null) == "merge" then
      lib.mkMerge (map (overLeaves f) v.contents)
    else if v ? _type && v ? content then
      overLeaves f v.content
    else
      f v;
in
{
  # Which floe declared each bundle a floe's module returned, as a config
  # fragment to merge beside it.
  #
  # `bundles.foo = x` desugars to `bundles = { foo = x; }`, so a floe writing
  # dotted paths is covered, and `mapAttrs` does not force values, so a
  # bundle body wrapped in its own `mkMerge` is never evaluated here.
  stampFloe =
    { name, moduleOutput }:
    overLeaves (
      body:
      lib.optionalAttrs (body ? bundles) {
        # The inner walk matters as much as the outer one: a floe may write
        # `bundles.<n> = mkIf cond { … }`, and stamping that leaf
        # unconditionally would bring the bundle into existence under a false
        # condition carrying nothing but its provenance.
        bundles = overLeaves (
          bundles: lib.mapAttrs (_: bundle: overLeaves (_: { floe = name; }) bundle) bundles
        ) body.bundles;
      }
    ) moduleOutput;
}

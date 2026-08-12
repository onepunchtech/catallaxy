{
  pkgs,
  packages,
  rustToolchain,
}:

pkgs.mkShell {
  packages = packages.tools ++ [
    packages.cataWrapped
    rustToolchain
    pkgs.bacon
    pkgs.rust-analyzer
    pkgs.mdbook
    pkgs.mdbook-mermaid

    (pkgs.writeShellScriptBin "cata-dev" ''
      exec cargo run --manifest-path "''${CATALLAXY_ROOT:-$(git rev-parse --show-toplevel)}/cli/Cargo.toml" -- "$@"
    '')
  ];

  shellHook = ''
    echo "catallaxy dev shell"
    echo "  cata                 # released CLI"
    echo "  cata-dev             # run CLI from source (cargo build + run)"
    echo "  cargo build          # build CLI"
    echo "  bacon                # watch + rebuild on change"
    echo "  nix build .#docs     # build the book"
    echo "  nix develop .#<lab>  # a lab's tools + its CA trust"
  '';
}

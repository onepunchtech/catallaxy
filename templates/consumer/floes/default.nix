{ mkFloe, lib }:
{
  hello-world = import ./hello-world { inherit mkFloe lib; };
}

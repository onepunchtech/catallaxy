{ floeOptions, lib }:
{
  hello-world = import ./hello-world { inherit floeOptions lib; };
}

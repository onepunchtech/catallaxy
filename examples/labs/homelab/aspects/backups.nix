{ ... }:
{
  floes.seaweedfs.enable = true;

  floes.velero = {
    enable = true;
    local.enable = true;
    schedules.daily = {
      schedule = "0 2 * * *";
      ttl = "168h";
    };
  };
}

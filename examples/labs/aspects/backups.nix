# Velero backups with SeaweedFS S3 storage (local dev)
{ ... }:
{
  components.seaweedfs.enable = true;

  components.velero = {
    enable = true;
    local.enable = true;
    schedules.daily = {
      schedule = "0 2 * * *";
      ttl = "168h"; # 7 days
    };
  };
}

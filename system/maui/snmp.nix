{
  config,
  ...
}:
{
  services.prometheus.exporters.snmp = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9116;
    environmentFile = config.sops.secrets.snmp_exporter_env.path;
    configuration = {
      auths = {
        tamatoa_v3 = {
          version = 3;
          username = "promro";
          security_level = "authPriv";
          auth_protocol = "SHA";
          password = "$SNMP_TAMATOA_AUTH_PASS";
          priv_protocol = "AES";
          priv_password = "$SNMP_TAMATOA_PRIV_PASS";
        };
        teka_v3 = {
          version = 3;
          username = "promro";
          security_level = "authPriv";
          auth_protocol = "SHA";
          password = "$SNMP_TEKA_AUTH_PASS";
          priv_protocol = "AES";
          priv_password = "$SNMP_TEKA_PRIV_PASS";
        };
      };

      modules = {
        brocade_if_mib = {
          walk = [
            "1.3.6.1.2.1.1.3"
            "1.3.6.1.2.1.2.2.1.2"
            "1.3.6.1.2.1.2.2.1.7"
            "1.3.6.1.2.1.2.2.1.8"
            "1.3.6.1.2.1.2.2.1.13"
            "1.3.6.1.2.1.2.2.1.14"
            "1.3.6.1.2.1.2.2.1.19"
            "1.3.6.1.2.1.2.2.1.20"
            "1.3.6.1.2.1.31.1.1.1.1"
            "1.3.6.1.2.1.31.1.1.1.6"
            "1.3.6.1.2.1.31.1.1.1.7"
            "1.3.6.1.2.1.31.1.1.1.10"
            "1.3.6.1.2.1.31.1.1.1.11"
            "1.3.6.1.2.1.31.1.1.1.15"
            "1.3.6.1.2.1.31.1.1.1.18"
          ];
          metrics =
            let
              ifIndexes = [
                {
                  labelname = "ifIndex";
                  type = "gauge";
                }
              ];
              ifLookups = [
                {
                  labels = [ "ifIndex" ];
                  labelname = "ifDescr";
                  oid = "1.3.6.1.2.1.2.2.1.2";
                  type = "DisplayString";
                }
                {
                  labels = [ "ifIndex" ];
                  labelname = "ifName";
                  oid = "1.3.6.1.2.1.31.1.1.1.1";
                  type = "DisplayString";
                }
                {
                  labels = [ "ifIndex" ];
                  labelname = "ifAlias";
                  oid = "1.3.6.1.2.1.31.1.1.1.18";
                  type = "DisplayString";
                }
              ];
              mkIfMetric = name: oid: type: help: {
                inherit
                  name
                  oid
                  type
                  help
                  ;
                indexes = ifIndexes;
                lookups = ifLookups;
              };
            in
            [
              {
                name = "sysUpTime";
                oid = "1.3.6.1.2.1.1.3";
                type = "gauge";
                help = "SNMPv2-MIB system uptime in hundredths of a second";
              }
              (mkIfMetric "ifAdminStatus" "1.3.6.1.2.1.2.2.1.7" "gauge"
                "Desired state of interface (1=up, 2=down)"
              )
              (mkIfMetric "ifOperStatus" "1.3.6.1.2.1.2.2.1.8" "gauge"
                "Operational state of interface (1=up, 2=down)"
              )
              (mkIfMetric "ifHighSpeed" "1.3.6.1.2.1.31.1.1.1.15" "gauge" "Interface nominal bandwidth in Mbps")
              (mkIfMetric "ifHCInOctets" "1.3.6.1.2.1.31.1.1.1.6" "counter" "64-bit inbound octets")
              (mkIfMetric "ifHCOutOctets" "1.3.6.1.2.1.31.1.1.1.10" "counter" "64-bit outbound octets")
              (mkIfMetric "ifHCInUcastPkts" "1.3.6.1.2.1.31.1.1.1.7" "counter" "64-bit inbound unicast packets")
              (mkIfMetric "ifHCOutUcastPkts" "1.3.6.1.2.1.31.1.1.1.11" "counter"
                "64-bit outbound unicast packets"
              )
              (mkIfMetric "ifInErrors" "1.3.6.1.2.1.2.2.1.14" "counter" "Inbound packet errors")
              (mkIfMetric "ifOutErrors" "1.3.6.1.2.1.2.2.1.20" "counter" "Outbound packet errors")
              (mkIfMetric "ifInDiscards" "1.3.6.1.2.1.2.2.1.13" "counter" "Inbound packet discards")
              (mkIfMetric "ifOutDiscards" "1.3.6.1.2.1.2.2.1.19" "counter" "Outbound packet discards")
            ];
        };

        synology = {
          walk = [
            "1.3.6.1.2.1.1.3"
            "1.3.6.1.4.1.6574.1"
            "1.3.6.1.4.1.6574.2.1.1"
            "1.3.6.1.4.1.6574.3.1.1"
            "1.3.6.1.2.1.25.2.3.1"
          ];
          metrics =
            let
              diskIndexes = [
                {
                  labelname = "diskIndex";
                  type = "gauge";
                }
              ];
              diskLookups = [
                {
                  labels = [ "diskIndex" ];
                  labelname = "diskID";
                  oid = "1.3.6.1.4.1.6574.2.1.1.2";
                  type = "DisplayString";
                }
                {
                  labels = [ "diskIndex" ];
                  labelname = "diskModel";
                  oid = "1.3.6.1.4.1.6574.2.1.1.3";
                  type = "DisplayString";
                }
              ];
              raidIndexes = [
                {
                  labelname = "raidIndex";
                  type = "gauge";
                }
              ];
              raidLookups = [
                {
                  labels = [ "raidIndex" ];
                  labelname = "raidName";
                  oid = "1.3.6.1.4.1.6574.3.1.1.2";
                  type = "DisplayString";
                }
              ];
              hrIndexes = [
                {
                  labelname = "hrStorageIndex";
                  type = "gauge";
                }
              ];
              hrLookups = [
                {
                  labels = [ "hrStorageIndex" ];
                  labelname = "hrStorageDescr";
                  oid = "1.3.6.1.2.1.25.2.3.1.3";
                  type = "DisplayString";
                }
              ];
            in
            [
              {
                name = "sysUpTime";
                oid = "1.3.6.1.2.1.1.3";
                type = "gauge";
                help = "SNMPv2-MIB system uptime in hundredths of a second";
              }
              {
                name = "synoSystemStatus";
                oid = "1.3.6.1.4.1.6574.1.1";
                type = "gauge";
                help = "Synology system health status (1=Normal, 2=Failed)";
              }
              {
                name = "synoSystemTemperature";
                oid = "1.3.6.1.4.1.6574.1.2";
                type = "gauge";
                help = "Synology NAS chassis temperature in Celsius";
              }
              {
                name = "synoPowerStatus";
                oid = "1.3.6.1.4.1.6574.1.3";
                type = "gauge";
                help = "Synology power supply status (1=Normal, 2=Failed)";
              }
              {
                name = "synoSystemFanStatus";
                oid = "1.3.6.1.4.1.6574.1.4.1";
                type = "gauge";
                help = "Synology system fan status (1=Normal, 2=Failed)";
              }
              {
                name = "synoCpuFanStatus";
                oid = "1.3.6.1.4.1.6574.1.4.2";
                type = "gauge";
                help = "Synology CPU fan status (1=Normal, 2=Failed)";
              }
              {
                name = "synoUpgradeAvailable";
                oid = "1.3.6.1.4.1.6574.1.5.4";
                type = "gauge";
                help = "DSM firmware update availability (1=Available, 2=Unavailable)";
              }
              {
                name = "synoDiskStatus";
                oid = "1.3.6.1.4.1.6574.2.1.1.5";
                type = "gauge";
                help = "Synology physical disk partition status (1=Normal, 4=SystemPartitionFailed, 5=Crashed)";
                indexes = diskIndexes;
                lookups = diskLookups;
              }
              {
                name = "synoDiskTemperature";
                oid = "1.3.6.1.4.1.6574.2.1.1.6";
                type = "gauge";
                help = "Synology physical disk temperature in Celsius";
                indexes = diskIndexes;
                lookups = diskLookups;
              }
              {
                name = "synoDiskHealthStatus";
                oid = "1.3.6.1.4.1.6574.2.1.1.13";
                type = "gauge";
                help = "Synology physical disk SMART/health status (1=Normal, 2=Warning, 3=Critical, 4=Failing)";
                indexes = diskIndexes;
                lookups = diskLookups;
              }
              {
                name = "synoRaidStatus";
                oid = "1.3.6.1.4.1.6574.3.1.1.3";
                type = "gauge";
                help = "Synology RAID/pool status (1=Normal, 11=Degraded, 12=Crashed)";
                indexes = raidIndexes;
                lookups = raidLookups;
              }
              {
                name = "synoRaidFreeSizeBytes";
                oid = "1.3.6.1.4.1.6574.3.1.1.4";
                type = "gauge";
                help = "Synology RAID/pool free bytes";
                indexes = raidIndexes;
                lookups = raidLookups;
              }
              {
                name = "synoRaidTotalSizeBytes";
                oid = "1.3.6.1.4.1.6574.3.1.1.5";
                type = "gauge";
                help = "Synology RAID/pool total bytes";
                indexes = raidIndexes;
                lookups = raidLookups;
              }
              {
                name = "hrStorageAllocationUnits";
                oid = "1.3.6.1.2.1.25.2.3.1.4";
                type = "gauge";
                help = "HOST-RESOURCES storage allocation unit size in bytes";
                indexes = hrIndexes;
                lookups = hrLookups;
              }
              {
                name = "hrStorageSize";
                oid = "1.3.6.1.2.1.25.2.3.1.5";
                type = "gauge";
                help = "HOST-RESOURCES storage size in allocation units";
                indexes = hrIndexes;
                lookups = hrLookups;
              }
              {
                name = "hrStorageUsed";
                oid = "1.3.6.1.2.1.25.2.3.1.6";
                type = "gauge";
                help = "HOST-RESOURCES storage used in allocation units";
                indexes = hrIndexes;
                lookups = hrLookups;
              }
            ];
        };
      };
    };
  };
}

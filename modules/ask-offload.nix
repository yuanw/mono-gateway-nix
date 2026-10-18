# ASK Hardware Offload Fast Path
# CDX, FCI, CMM, FMC, auto-bridge, dpa-app — with typed NixOS options
{ config, lib, pkgs, ... }:

let
  cfg = config.mono-gateway.ask;
in
{
  options.mono-gateway.ask = {
    enable = lib.mkEnableOption "ASK hardware offload fast path";

    conntrackMax = lib.mkOption {
      type = lib.types.int;
      default = 131072;
      description = "Maximum conntrack entries for CMM and nf_conntrack";
    };

    fastforwardConfigFile = lib.mkOption {
      type = lib.types.path;
      default = ../pkgs/cmm/fastforward;
      description = "CMM fastforward exclusion rules config file";
    };

    ipsecOffload = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Let the NXP IPsec fast path hand its SAs to cmm. Set this to false
        for a box that *terminates* IPsec: the offload is key-engine driven
        and assumes a forwarded SA, so a locally-terminated tunnel leaves
        the child SAs at 0 bytes and no ESP goes out.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # --- IPsec: keep the SAs in software ---
    # The NXP IPsec fast path (net/xfrm/xfrm_policy.c under IPSEC_FLOW_CACHE,
    # plus CONFIG_INET_IPSEC_OFFLOAD) pushes every SA's handles and tunnel
    # header to userspace: ipsec_flow_add() fills the kernel flow cache and
    # pfkey_send_notify -> ipsec_nlkey_send() tells the key engine. keytrack.c
    # picks that up and cmm programs FPP_CMD_IPSEC_SA_TNL_ROUTE into the FMan.
    # That assumes a *forwarded* SA: for a locally-terminated tunnel
    # __cmmRouteRegister fails ("route sa entry add failed") yet the FPP
    # command is still issued, and the datapath is broken -- child SAs at 0
    # bytes, no ESP.
    #
    # cmm has no runtime switch, so cut both kernel paths at the source.
    # Patching only the flow-cache hook still leaves two handles in cmm's
    # table. Turning CONFIG_INET_IPSEC_OFFLOAD off instead does not build (NXP
    # reads skb->ipsec_offload unguarded from a dev_queue_xmit helper), hence
    # the short-circuit. Forwarding/NAT offload is CPE_FAST_PATH/CDX, a
    # different path, and keeps working. The greps make a silent no-op a build
    # failure.
    nixpkgs.overlays = lib.mkIf (!cfg.ipsecOffload) [
      (_final: prev: {
        mono-gateway-kernel = prev.mono-gateway-kernel.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            sed -i 's/if (ipsec_flow_add(/if (0 && ipsec_flow_add(/g' net/xfrm/xfrm_policy.c
            sed -i 's/ipsec_nlkey_send(net, x, c);/if (0) ipsec_nlkey_send(net, x, c);/' net/key/af_key.c
            test "$(grep -c 'if (0 && ipsec_flow_add(' net/xfrm/xfrm_policy.c)" -ge 2 || {
              echo "FAILED: xfrm_policy.c ipsec_flow_add call sites not short-circuited"
              exit 1
            }
            grep -q 'if (0) ipsec_nlkey_send(net, x, c);' net/key/af_key.c || {
              echo "FAILED: af_key.c ipsec_nlkey_send not short-circuited"
              exit 1
            }
          '';
        });
      })
    ];

    # --- Out-of-tree kernel modules ---
    boot.extraModulePackages = [
      pkgs.mono-gateway-auto-bridge
      pkgs.mono-gateway-cdx
      pkgs.mono-gateway-fci
    ];

    # auto_bridge has no dependencies, load early
    boot.kernelModules = [ "auto_bridge" ];

    # --- Conntrack tuning ---
    boot.kernel.sysctl = {
      "net.netfilter.nf_conntrack_acct" = 1;
      "net.netfilter.nf_conntrack_checksum" = 0;
      "net.netfilter.nf_conntrack_max" = cfg.conntrackMax;
      "net.netfilter.nf_conntrack_tcp_timeout_established" = 7440;
      "net.netfilter.nf_conntrack_udp_timeout" = 60;
      "net.netfilter.nf_conntrack_udp_timeout_stream" = 180;
    };

    # --- CDX + FCI module loading ---
    # CDX calls dpa_app as a usermode helper, which needs /etc/*.xml config files
    # to be present (created by environment.etc / systemd-tmpfiles).
    systemd.services.load-ask-modules = {
      description = "Load ASK Fast Path Kernel Modules (CDX + FCI)";
      after = [ "systemd-tmpfiles-setup.service" ];
      wants = [ "systemd-tmpfiles-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      before = [ "cmm.service" ];
      unitConfig.ConditionPathIsDirectory = "/sys/bus/fsl-mc";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${pkgs.kmod}/bin/modprobe cdx"
          "${pkgs.kmod}/bin/modprobe fci"
        ];
      };
    };

    # --- CMM fast path daemon ---
    systemd.services.cmm = {
      description = "CMM Connection Management Module for ASK Fast Path";
      after = [ "network.target" "load-ask-modules.service" ];
      wants = [ "load-ask-modules.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/dev/cdx_ctrl";
      serviceConfig = {
        Type = "forking";
        ExecStartPre = "-/bin/sh -c 'test -e /sys/class/vwd/vwd0/vwd_fast_path_enable && echo 1 > /sys/class/vwd/vwd0/vwd_fast_path_enable'";
        ExecStart = "${pkgs.mono-gateway-cmm}/bin/cmm -f /etc/config/fastforward -n ${toString cfg.conntrackMax}";
        ExecStopPost = "-/bin/sh -c 'test -e /sys/class/vwd/vwd0/vwd_fast_path_enable && echo 0 > /sys/class/vwd/vwd0/vwd_fast_path_enable'";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # --- Config files ---
    # DPA-App config files (dpa_app expects these at /etc/)
    environment.etc."cdx_cfg.xml".source = "${pkgs.mono-gateway-dpa-app}/etc/cdx_cfg.xml";
    environment.etc."cdx_pcd.xml".source = "${pkgs.mono-gateway-dpa-app}/etc/cdx_pcd.xml";
    environment.etc."cdx_sp.xml".source = "${pkgs.mono-gateway-dpa-app}/etc/cdx_sp.xml";

    # FMC PDL config (dpa_app expects at /etc/fmc/config/)
    environment.etc."fmc/config/hxs_pdl_v3.xml".source = "${pkgs.mono-gateway-fmc}/etc/fmc/config/hxs_pdl_v3.xml";

    # CMM fastforward config
    environment.etc."config/fastforward".source = cfg.fastforwardConfigFile;

    # --- ASK userspace tools ---
    environment.systemPackages = [
      pkgs.mono-gateway-fmc
      pkgs.mono-gateway-dpa-app
      pkgs.mono-gateway-cmm
    ];
  };
}

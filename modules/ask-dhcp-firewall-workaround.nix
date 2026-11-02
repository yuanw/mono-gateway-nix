# ASK board: keep BOOTP alive through the nixpkgs nftables rpfilter chain
{ config, lib, pkgs, ... }:

let
  cfg = config.mono-gateway.ask;
in
{
  options.mono-gateway.ask.dhcpRpfBypass = lib.mkEnableOption ''
    DHCP bypass rules for the nixpkgs nftables firewall on the ASK kernel

    Fresh BOOTP broadcasts (saddr 0.0.0.0, udp 68 -> 67) are dropped by the
    =inet nixos-fw= rpfilter chain's policy: its generated exemption
    (meta nfproto ipv4 udp sport . udp dport { 68 . 67, 67 . 68 }) never
    matches on this board, so no new client ever reaches dnsmasq while
    unicast RENEWs keep the existing leases alive. A second layer,
    loose rp_filter (sysctl =2=, also set by the firewall module), rejects
    saddr 0.0.0.0 at the routing decision. Counter-proven 2026-11-01:
    with the accepts inserted, DISCOVER -> ACK in one retry cycle; without,
    nothing arrives at the socket. The concat-exemption failure is
    presumably a kernel difference (works on the same nixpkgs elsewhere) —
    candidate for an upstream nixpkgs issue against
    nixos/modules/services/networking/firewall-nftables.nix.
  '';

  config = lib.mkIf cfg.dhcpRpfBypass {
    # Loose RPF still rejects saddr 0.0.0.0; the rpfilter chain's fib check
    # is the reverse-path filter we actually want.
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.br-lan.rp_filter" = 0;
      "net.ipv4.conf.eth1.rp_filter" = 0;
    };

    systemd.services.dhcp-ask-rpf-bypass = {
      description = "Open DHCP holes in the nixpkgs nftables rpfilter chain";
      after = [ "nftables.service" "cmm.service" ];
      requires = [ "nftables.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "dhcp-ask-rpf-bypass" ''
          set -e
          # wait for the table to exist at all
          for i in $(seq 1 30); do
            ${pkgs.nftables}/bin/nft list table inet nixos-fw >/dev/null 2>&1 && break
            sleep 1
          done
          ${pkgs.nftables}/bin/nft list table inet nixos-fw >/dev/null || { echo "nixos-fw table missing — DHCP needs no bypass"; exit 0; }
          # idempotent: only insert when our hole is not already there
          ${pkgs.nftables}/bin/nft list chain inet nixos-fw rpfilter | grep -q 'dhcp-ask-bypass' || \
            ${pkgs.nftables}/bin/nft insert rule inet nixos-fw rpfilter \
              ip saddr 0.0.0.0 udp sport 68 udp dport 67 accept comment "dhcp-ask-bypass"
          ${pkgs.nftables}/bin/nft list chain inet nixos-fw input | grep -q 'dhcp-ask-bypass' || \
            ${pkgs.nftables}/bin/nft insert rule inet nixos-fw input \
              ip saddr 0.0.0.0 udp sport 68 udp dport 67 accept comment "dhcp-ask-bypass"
        '';
      };
    };
  };
}

{ config, lib, ... }:

{
  microvm.interfaces = [
    {
      type = "user";
      id = "usernet";
      mac = "02:00:00:00:00:01";
    }
  ];

  networking.useNetworkd = true;
  systemd.network.wait-online = {
    enable = true;
    anyInterface = true;
  };

  # Over IPv6, slirp would reach the host and the LAN at their global
  # addresses, which no fixed range describes.
  networking.enableIPv6 = false;

  # The guest's one interface gets IPv4 over DHCP and nothing over IPv6:
  # without link-local addressing, networkd leaves IPv6 disabled on it
  # and runs no router discovery. networkd applies the first matching
  # unit in lexical order, so this one wins over NixOS's generic
  # 99-ethernet-default-dhcp.
  systemd.network.networks."10-usernet" = {
    matchConfig.MACAddress = (lib.head config.microvm.interfaces).mac;
    networkConfig = {
      DHCP = "ipv4";
      LinkLocalAddressing = "no";
    };
  };

  # The guest resolves names through systemd-resolved on 127.0.0.53,
  # which asks the DNS server that DHCP names, slirp's 10.0.2.3, and no
  # other: without fallback servers it never turns to its built-in public
  # ones, such as 1.1.1.1, which it does while no link has a DNS server,
  # as early in boot. It runs no LLMNR or multicast DNS, so it neither
  # listens for name queries on the link nor sends any there.
  services.resolved = {
    enable = true;
    settings.Resolve = {
      FallbackDNS = [ ];
      LLMNR = false;
      MulticastDNS = false;
    };
  };

  # systemd-timesyncd would contact the NixOS NTP pool on its own. The
  # guest's clock source is kvm-clock, which takes the time from the host
  # at boot and keeps in step with the host's clock, and on which the TLS
  # certificate checks in the guest depend.
  services.timesyncd.enable = false;

  # Of everything outside the guest, only the internet over IPv4 is
  # reachable, with three exceptions: DHCP to slirp at 10.0.2.2; DNS through
  # 10.0.2.3, which slirp forwards to the first nameserver of the host's
  # resolv.conf, which may be on the host's loopback or its LAN; and the
  # broker port of the launch, which the setup of the broker-access input
  # admits at boot. slirp sends guest traffic out through the host's network
  # stack, so a private, CGNAT or link-local destination is the host or its
  # LAN, and multicast reaches no further than the LAN; slirp hands 10.0.2.2
  # and the broadcast address 255.255.255.255 to the host's loopback.
  # networkd sends DHCP renewals and releases from port 68, a privileged
  # port that agent cannot bind, and its other DHCP messages over a packet
  # socket, which this hook does not see. reject makes a refused connection
  # fail at once.
  networking.nftables = {
    enable = true;
    tables.egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          oif "lo" accept
          ip daddr 10.0.2.2 udp sport 68 udp dport 67 accept
          ip daddr 10.0.2.3 meta l4proto { tcp, udp } th dport 53 accept
          ip daddr {
            10.0.0.0/8,
            100.64.0.0/10,
            169.254.0.0/16,
            172.16.0.0/12,
            192.168.0.0/16,
            224.0.0.0/4,
            255.255.255.255
          } reject
          meta nfproto ipv6 reject
        }
      '';
    };
  };
}

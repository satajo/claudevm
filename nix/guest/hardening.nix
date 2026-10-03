{ lib, pkgs, ... }:

{
  # Opening a static device node, creating a socket of an unregistered
  # family or netlink protocol and looking up a generic netlink family by
  # name make the kernel load the module behind it, for any user. The
  # guest uses none of these modules.
  boot.blacklistedKernelModules = [
    # The host side of virtualization: vhost and VFIO devices and the
    # vsock family.
    "vhost" "vhost_net" "vhost_vsock"
    "vsock" "vsock_diag" "vsock_loopback" "hv_sock" "vmw_vsock_vmci_transport"
    "vmw_vsock_virtio_transport" "vmw_vsock_virtio_transport_common"
    "vfio" "vfio_iommu_type1" "vfio_pci"
    # KVM, with which the guest would host VMs of its own; microvm.cpu
    # already hides the svm and vmx extensions it needs.
    "kvm" "kvm_amd" "kvm_intel"
    # Socket families, the sock_diag modules that load them, and netlink
    # protocols.
    "af_alg" "af_key" "appletalk" "atm" "ax25" "bluetooth" "caif_socket"
    "can" "ieee802154_socket" "kcm" "l2tp_ip" "l2tp_ip6" "llc2"
    "mpls_router" "netrom" "nfc" "phonet" "pppox" "qrtr" "rds" "rose"
    "rxrpc" "sctp" "sctp_diag" "smc" "smc_diag" "tipc" "tipc_diag" "x25"
    "crypto_user" "ib_core" "scsi_transport_iscsi" "xfrm_user"
    # The tun device.
    "tun"
    # Generic netlink families.
    "wireguard" "openvswitch" "ip_vs" "batman_adv" "gtp" "macsec" "nbd"
    "l2tp_netlink" "ovpn" "cfg80211"
  ];

  # No process in the guest leaves a core dump. Without systemd-coredump,
  # none is stored under /var/lib/systemd/coredump on the RAM-backed root.
  systemd.coredump.enable = false;

  boot.kernel.sysctl = {
    # The kernel pipes every core dump to false, which exits without
    # reading it, so no core file appears in the working directory of the
    # crashing process either, which may be the workspace or another share
    # on the host. A pipe ignores RLIMIT_CORE, which the session's
    # processes start with unlimited, soft and hard, so this holds for
    # every process.
    "kernel.core_pattern" = "|${lib.getExe' pkgs.coreutils "false"}";
    # Refuses io_uring_setup to every process, root included.
    "kernel.io_uring_disabled" = 2;
    # TIOCSETD on any terminal, a pty included, would otherwise load the
    # line discipline module it names.
    "dev.tty.ldisc_autoload" = 0;
    # No user namespaces, not even for root. Setting
    # security.allowUserNamespaces = false has the same effect but also
    # requires nix.settings.sandbox = false, while the Nix daemon builds
    # in its sandbox without user namespaces.
    "user.max_user_namespaces" = 0;
  };

  # Only root can open these device nodes, listed by kernel name with
  # their static node's path under /dev, or null for a node that exists
  # only while its module is loaded. The process that opens /dev/fuse can
  # serve a FUSE file system, which only root can mount: the guest has no
  # setuid fusermount and no user namespaces; the fuse module stays
  # loaded, as virtiofs is built on it. The modules behind the other nodes
  # are blacklisted, and with mode 0600 a loaded one would still be out of
  # the agent's reach. The kernel package ships them, so /dev/net/tun,
  # /dev/vfio/vfio, /dev/vhost-net and /dev/vhost-vsock exist as static
  # nodes, which answer an open with ENODEV; vsock takes a dynamic minor,
  # so /dev/vsock appears only once its module loads. systemd's default
  # udev rules give all six nodes mode 0666, and its tmpfiles
  # configuration gives the static ones the same at boot. A rule applies
  # on the device event of its node, and no device event fires for the
  # node of a module that is not loaded, so each static node is also
  # named with static_node: udevd applies such rules at startup, after
  # tmpfiles has run, in file order. NixOS installs these rules as
  # 99-local.rules, after systemd's 50-udev-default.rules.
  services.udev.extraRules = lib.concatStrings (lib.mapAttrsToList
    (kernel: node: ''
      SUBSYSTEM=="misc", KERNEL=="${kernel}", MODE="0600"${lib.optionalString (node != null) '', OPTIONS+="static_node=${node}"''}
    '')
    {
      fuse = "fuse";
      tun = "net/tun";
      vfio = "vfio/vfio";
      vhost-net = "vhost-net";
      vhost-vsock = "vhost-vsock";
      vsock = null;
    });

  # Root is locked and the session starts as agent, so no program in the
  # guest needs to raise privileges: no sudo, and no setuid or
  # file-capability wrappers such as su, mount or newuidmap.
  security.sudo.enable = false;
  security.enableWrappers = false;
}

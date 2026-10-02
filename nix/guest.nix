{ config, lib, pkgs, ... }:

let
  cfg = config.claudevm;
  agent = config.users.users.agent;
  agentGid = config.users.groups.${agent.group}.gid;

  # The journal lives in RAM, outside agent.slice, and keeps at most this
  # many MiB.
  journalMaxMiB = 16;

  # The guest's RAM that agent.slice leaves to the rest of the guest, the
  # same at every launch size. At idle the kernel, PID 1 and the guest's
  # services hold about 100 MiB that they cannot reclaim, about half of it
  # kernel memory charged to no cgroup. The journal may add journalMaxMiB,
  # and the rest is headroom for their page cache and growth.
  memoryReserveMiB = 256;

  # The shares every launch has. Relative share sources resolve against the
  # runtime directory the claudevm wrapper cds into before starting
  # virtiofsd, where "launch" is a plain directory of per-invocation launch
  # input. The workspace and the other host directories of a launch come
  # from the launch input "mounts" instead.
  shares = [
    {
      tag = "ro-store";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto = "virtiofs";
      readOnly = true;
      posixAcl = false;
    }
    {
      tag = "launch";
      source = "launch";
      mountPoint = "/mnt/launch";
      proto = "virtiofs";
      readOnly = true;
      posixAcl = false;
    }
  ];

  # The launch input "mounts" lists the host directories a launch shares,
  # the workspace first, as NUL-terminated tag, path, mode (ro or rw)
  # triples. The host serves each tag on the socket <tag>.sock and the guest
  # mounts it at path, the same absolute path the directory has on the host.
  readMount = ''IFS= read -r -d "" tag && IFS= read -r -d "" path && IFS= read -r -d "" mode'';

  # The launch input "forward-path" lists the bin directories of the
  # packages the host built for the launch as NUL-terminated store paths,
  # which the guest sees through the ro-store share. This puts them in front
  # of PATH in that order; an empty list leaves PATH unchanged.
  prependForwardPath = ''
    PATH="$(${lib.getExe' pkgs.coreutils "tr"} '\0' : < /mnt/launch/forward-path)$PATH"
  '';

  # Each virtiofsd lets the guest hold CLAUDEVM_SHARE_FDS host descriptors,
  # which the launcher writes into /mnt/launch/env: one for every inode of
  # its share that the guest kernel holds and one more for every open file
  # and directory. Once the guest holds them all, the daemon answers every
  # further open, and every lookup of an inode the guest does not hold yet,
  # with ENFILE; the host itself never runs out. This sets share_fds.
  shareBudget = ''
    share_fds=''${CLAUDEVM_SHARE_FDS:?is not set in /mnt/launch/env}
    if ! [[ $share_fds =~ ^[1-9][0-9]*$ ]]; then
      echo "CLAUDEVM_SHARE_FDS=$share_fds is not a positive integer" >&2
      exit 1
    fi
  '';

  # Emits the per-launch QEMU arguments: the VM size from CLAUDEVM_VCPU and
  # CLAUDEVM_MEM (MiB) and a vhost-user-fs device per entry of the launch
  # input "mounts". QEMU applies the last -smp and -m it is given, so these
  # override the baked ones. The baked memory backend of NUMA node 0 has the
  # fixed size microvm.mem and the backends of all nodes must add up to -m,
  # so the rest of the requested RAM forms a second node. microvm.mem is
  # therefore also the smallest RAM a launch can have. Runs with the runtime
  # directory as working directory, like virtiofsd-run.
  launchArgs = pkgs.writeShellApplication {
    name = "claudevm-launch-args";
    text = ''
      vcpu=$CLAUDEVM_VCPU
      mem=$CLAUDEVM_MEM
      extra_mem=$((mem - ${toString config.microvm.mem}))
      if [ "$extra_mem" -lt 0 ]; then
        echo "claudevm-launch-args: CLAUDEVM_MEM=$mem is below ${toString config.microvm.mem}" >&2
        exit 1
      fi
      args=(-smp "$vcpu" -m "''${mem}M")
      if [ "$extra_mem" -gt 0 ]; then
        args+=(
          -object "memory-backend-memfd,id=mem-launch,size=''${extra_mem}M,share=on"
          -numa "node,memdev=mem-launch"
        )
      fi
      while IFS= read -r -d "" tag && IFS= read -r -d "" _ && IFS= read -r -d "" _; do
        args+=(
          -chardev "socket,id=$tag,path=$tag.sock"
          -device "vhost-user-fs-pci,chardev=$tag,tag=$tag"
        )
      done < launch/mounts
      echo "''${args[*]}"
    '';
  };

  # The Claude Code config of the image, which every session starts from
  # and nothing from the host adds to. Claude Code asks once per
  # installation to accept bypass permissions mode and records the answer
  # in settings.json; syncClaudeAiPlugins = false keeps the plugins enabled
  # on the claude.ai account out of the VM.
  claudeSettings = pkgs.writeText "claude-settings.json" (builtins.toJSON {
    skipDangerousModePermissionPrompt = true;
    syncClaudeAiPlugins = false;
  });
  # claudevm-home adds the guest key of the launch to the approved custom
  # API keys. Claude Code looks an approved key up by its last 20
  # characters; the full key is approved as well so that either lookup
  # matches. claudevm-home also sets hasTrustDialogAccepted for the
  # workspace, the record of an accepted workspace trust dialog. Claude
  # Code requires it, in an interactive session and in a -p run alike,
  # before it applies the hooks, permissions, extraKnownMarketplaces and
  # enabledPlugins of a repository's .claude/settings.json and loads the
  # plugins under its .claude/skills/<name>/.
  claudeState = pkgs.writeText "claude.json" (builtins.toJSON {
    hasCompletedOnboarding = true;
    theme = "dark";
    customApiKeyResponses.rejected = [ ];
  });

  claudeSession = pkgs.writeShellApplication {
    name = "claude-session";
    runtimeInputs = [
      cfg.claudeCode
      pkgs.coreutils
      pkgs.bashInteractive
    ];
    text = ''
      set -a
      # shellcheck disable=SC1091
      . /mnt/launch/env
      set +a
      # Claude Code shows no workspace trust dialog when this says it runs
      # in a sandbox. The trust that repository content needs comes from
      # hasTrustDialogAccepted in ~/.claude.json, which claudevm-home sets.
      export CLAUDE_CODE_SANDBOXED=1
      # The guest key is all the guest holds, and the session's
      # environment carries it only as ANTHROPIC_API_KEY. The broker on the
      # host loopback, which QEMU forwards 10.0.2.2 to, swaps it for the
      # token.
      export ANTHROPIC_API_KEY=$CLAUDEVM_GUEST_KEY
      unset CLAUDEVM_GUEST_KEY
      export ANTHROPIC_BASE_URL=http://10.0.2.2:$CLAUDEVM_BROKER_PORT
      export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      export DISABLE_AUTOUPDATER=1
      export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
      ${prependForwardPath}
      if [ -n "''${ROWS:-}" ] && [ -n "''${COLS:-}" ]; then
        stty rows "$ROWS" cols "$COLS" || true
      fi
      mapfile -d "" -t args < /mnt/launch/claude-args
      # The launch input "plugin-dirs" lists the guest paths of the plugin
      # directories of the launch as NUL-terminated paths.
      mapfile -d "" -t plugin_dirs < /mnt/launch/plugin-dirs
      plugin_args=()
      for dir in "''${plugin_dirs[@]}"; do
        plugin_args+=(--plugin-dir "$dir")
      done
      cd "$CLAUDEVM_WORKSPACE"
      case $CLAUDEVM_SESSION in
        claude) exec claude --dangerously-skip-permissions "''${plugin_args[@]}" "''${args[@]}" ;;
        shell) exec bash -l ;;
      esac
      echo "claude-session: unknown CLAUDEVM_SESSION '$CLAUDEVM_SESSION'" >&2
      exit 1
    '';
  };
in
{
  options.claudevm = {
    vcpu = lib.mkOption {
      type = lib.types.ints.positive;
      description = "vCPUs of a launch whose claudevm.toml sets no vcpu.";
    };
    memory = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Guest RAM in MiB of a launch whose claudevm.toml sets no memory.";
    };
    claudeCode = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "Claude Code package of the guest, also used by claudevm login on the host.";
    };
    virtiofsdReservedFds = lib.mkOption {
      type = lib.types.ints.positive;
      readOnly = true;
      default = 609;
      description = ''
        Descriptors that virtiofsd 1.14.0 keeps for itself besides one per
        thread of its pool: 509, one per memory region vhost-user can map,
        and 100 more. The guest may hold the rest of the daemon's limit.
      '';
    };
  };

  config = {
    networking.hostName = "claudevm";
    system.stateVersion = lib.trivial.release;

    nixpkgs.config.allowUnfreePredicate = pkg:
      lib.getName pkg == "claude-code";

    claudevm = {
      vcpu = 4;
      memory = 4096;
    };

    assertions = [
      {
        assertion = cfg.memory >= config.microvm.mem;
        message = "claudevm.memory must be at least microvm.mem (${toString config.microvm.mem} MiB)";
      }
      {
        assertion = config.microvm.virtiofsd.package.version == "1.14.0";
        message = "claudevm.virtiofsdReservedFds is the descriptor reserve of virtiofsd 1.14.0; check it against virtiofsd ${config.microvm.virtiofsd.package.version} and update the version in this assertion";
      }
    ];

    microvm = {
      hypervisor = "qemu";
      mem = 512;
      # The host CPU without the virtualization extensions svm and vmx, so
      # the guest kernel cannot run a hypervisor, and without sgx, with
      # which QEMU's microvm machine crashes.
      cpu = "host,+x2apic,-sgx,-svm,-vmx";
      qemu = {
        # microvm.nix defaults to the QEMU of every target architecture once
        # microvm.cpu is set; qemu_kvm, built for the host's architecture
        # only, keeps the closure about 600 MiB smaller.
        package = pkgs.qemu_kvm;
        # The runner's own serial console adds earlyprintk=ttyS0 to the
        # kernel command line, which makes the boot loader and the kernel
        # report their progress on the console the session appears on.
        # Serving the same chardev here leaves the command line to
        # boot.kernelParams.
        serialConsole = false;
        extraArgs = [
          # qboot, unlike the SeaBIOS that QEMU loads by default, prints no
          # version banner and resets no terminal, so the launch output
          # stays on screen.
          "-bios"
          "${config.microvm.qemu.package}/share/qemu/qboot.rom"
          "-serial"
          "chardev:stdio"
          # -enable-kvm, which the runner passes only while microvm.cpu is
          # unset, makes KVM required rather than tried before TCG.
          "-enable-kvm"
        ];
      };
      extraArgsScript = lib.getExe launchArgs;
      inherit shares;
      writableStoreOverlay = "/nix/.rw-store";
      interfaces = [
        {
          type = "user";
          id = "usernet";
          mac = "02:00:00:00:00:01";
        }
      ];
    };

    # The stock virtiofsd-run wraps the daemons in supervisord with
    # user=root, which refuses to start for an unprivileged user. This
    # replacement starts one virtiofsd per share and per entry of the launch
    # input "mounts" directly. Of the share options it honors socket,
    # source, cache and readOnly; posixAcl and extraArgs are not passed. It
    # exits as soon as any daemon exits. Each daemon runs
    # CLAUDEVM_SHARE_THREADS threads, in place of
    # microvm.virtiofsd.threadPoolSize, and may hold CLAUDEVM_SHARE_NOFILE
    # descriptors; the launcher sets both and derives from them how many
    # descriptors the guest may hold.
    microvm.binScripts.virtiofsd-run =
      let
        virtiofsShares = builtins.filter
          (share: share.proto == "virtiofs")
          config.microvm.shares;
      in
      lib.mkForce ''
        set -euo pipefail
        trap 'kill $(jobs -p) 2>/dev/null || true; wait' EXIT
        nofile=''${CLAUDEVM_SHARE_NOFILE:?is not set}
        threads=''${CLAUDEVM_SHARE_THREADS:?is not set}
        uid=$(${lib.getExe' pkgs.coreutils "id"} -u)
        gid=$(${lib.getExe' pkgs.coreutils "id"} -g)
        # serve SOCKET DIR CACHE ro|rw
        serve() {
          local readonly_flag=()
          if [ "$4" = ro ]; then
            readonly_flag=(--readonly)
          fi
          ${lib.getExe config.microvm.virtiofsd.package} \
            --socket-path="$1" \
            --shared-dir="$2" \
            --cache="$3" \
            --thread-pool-size "$threads" \
            --rlimit-nofile "$nofile" \
            --translate-uid map:${toString agent.uid}:"$uid":1 \
            --translate-gid map:${toString agentGid}:"$gid":1 \
            "''${readonly_flag[@]}" &
        }
        ${lib.concatMapStrings (share: ''
          serve ${lib.escapeShellArgs [
            share.socket
            share.source
            share.cache
            (if share.readOnly then "ro" else "rw")
          ]}
        '') virtiofsShares}
        while ${readMount}; do
          serve "$tag.sock" "$path" auto "$mode"
        done < launch/mounts
        wait -n
      '';

    # quiet also silences systemd's unit status lines. Log level 3 keeps
    # kernel messages less severe than critical off the console, among them
    # the harmless "PCI: Fatal: No config space access function found" of the
    # microvm machine; the journal still has them all. Mount failures and the
    # emergency shutdown come from systemd, which writes to the console
    # itself.
    boot.kernelParams = [ "console=ttyS0" "quiet" ];
    boot.consoleLogLevel = 3;

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
    # reachable, with three exceptions: DHCP to slirp at 10.0.2.2; DNS
    # through 10.0.2.3, which slirp forwards to the first nameserver of the
    # host's resolv.conf, which may be on the host's loopback or its LAN;
    # and the broker port of the launch, which claudevm-home admits at
    # boot. slirp sends guest traffic out through the host's network stack,
    # so a private, CGNAT or link-local destination is the host or its LAN,
    # and multicast reaches no further than the LAN; slirp hands 10.0.2.2
    # and the broadcast address 255.255.255.255 to the host's loopback.
    # networkd sends DHCP renewals and releases from port 68, a privileged
    # port that agent cannot bind, and its other DHCP messages over a
    # packet socket, which this hook does not see. reject makes a refused
    # connection fail at once.
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

    # The process that opens /dev/fuse can serve a FUSE file system, which
    # only root can mount: the guest has no setuid fusermount and no user
    # namespaces. The fuse module itself stays loaded, as virtiofs is built
    # on it.
    services.udev.extraRules = ''
      SUBSYSTEM=="misc", KERNEL=="fuse", MODE="0600"
    '';

    # Root is locked and the session starts as agent, so no program in the
    # guest needs to raise privileges: no sudo, and no setuid or
    # file-capability wrappers such as su, mount or newuidmap.
    security.sudo.enable = false;
    security.enableWrappers = false;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Login shells such as the debug shell reset PATH in
    # /etc/set-environment, which runs this last.
    environment.extraInit = lib.mkAfter prependForwardPath;

    # virtiofsd translates this uid and the gid of the users group (100) to
    # the invoking host user's ids, so the host ids are free to differ.
    users.users.agent = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };

    environment.systemPackages = [
      cfg.claudeCode
      pkgs.git
    ];

    # The session owns the serial console instead of a login prompt.
    systemd.services."serial-getty@ttyS0".enable = false;

    # A failed mount starts emergency mode, which with the locked root
    # account would leave the VM running with no session.
    systemd.services.emergency.serviceConfig.ExecStart = lib.mkForce [
      ""
      "${config.systemd.package}/bin/systemctl --no-block poweroff"
    ];

    systemd.services.claudevm-home = {
      description = "Prepare agent home, broker access, the open-file limit, the store ACL, the forward_packages registration, the agent memory limit, the store share's cover and shared directories from the launch share";
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      unitConfig.RequiresMountsFor = [ "/mnt/launch" ];
      onFailure = [ "poweroff.target" ];
      path = [ pkgs.util-linux pkgs.nftables pkgs.jq pkgs.acl ];
      enableStrictShellChecks = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        # shellcheck disable=SC1091
        . /mnt/launch/env
        : "''${CLAUDEVM_BROKER_PORT:?is not set in /mnt/launch/env}"
        : "''${CLAUDEVM_GUEST_KEY:?is not set in /mnt/launch/env}"
        : "''${CLAUDEVM_WORKSPACE:?is not set in /mnt/launch/env}"
        ${shareBudget}
        # Processes without CAP_SYS_ADMIN, everything the session runs among
        # them, may hold a quarter of the share budget open. Root's files
        # count towards fs.file-max too, but only root may exceed it. The
        # files the kernel keeps open behind a mapping of a store file,
        # working directories and the parents of everything held pin inodes
        # on a share without counting. systemd raises fs.file-max to the
        # largest value at boot.
        file_max=$((share_fds / 4))
        echo "$file_max" > /proc/sys/fs/file-max
        nft insert rule inet egress output \
          ip daddr 10.0.2.2 tcp dport "$CLAUDEVM_BROKER_PORT" accept
        # The guest's /nix/store shows the host's whole store. Its ACL lets
        # agent traverse it, so that every store path stays reachable by its
        # name, but not list it. The same goes for /nix/store/.links, where
        # a host that optimises its store keeps a link to every distinct
        # file of it; the ACL copies up only the directory itself. /nix/store
        # is a read-only bind mount for every process but the Nix processes
        # of root, the daemon among them, each of which remounts it
        # read-write in a mount namespace of its own; the ACLs are set the
        # same way. Their chmod of the store directory changes the ACL's
        # mask and keeps the entry for agent.
        unshare --mount -- ${pkgs.runtimeShell} -euc '
          mount -o remount,bind,rw /nix/store
          setfacl -m u:${agent.name}:x /nix/store
          if [ -e /nix/store/.links ]; then
            setfacl -m u:${agent.name}:x /nix/store/.links
          fi
        '
        # The launch input "forward-registration" is the Nix validity
        # registration, as nix-store --dump-db writes it, of the closure of
        # the forward_packages outputs, and "forward-outputs" lists those
        # outputs as NUL-terminated store paths, each once; both are empty
        # without forward_packages. A garbage collection, which every user
        # may ask the Nix daemon for, removes from the /nix/store overlay
        # every path that is not valid in the guest's Nix database or not
        # reachable from a garbage collection root. The database starts with
        # the system closure; the registration adds the closure of the
        # outputs, and the links under /nix/var/nix/gcroots root the
        # outputs. Root's nix-store opens the database itself, without the
        # daemon.
        ${config.nix.package.out}/bin/nix-store --load-db < /mnt/launch/forward-registration
        mkdir /nix/var/nix/gcroots/forward-packages
        xargs -0 -r ln -s -t /nix/var/nix/gcroots/forward-packages < /mnt/launch/forward-outputs
        # agent.slice may hold the guest's RAM less memoryReserveMiB.
        memtotal_kib=
        while read -r key value _; do
          if [ "$key" = MemTotal: ]; then
            memtotal_kib=$value
          fi
        done < /proc/meminfo
        : "''${memtotal_kib:?/proc/meminfo has no MemTotal}"
        agent_kib=$((memtotal_kib - ${toString (memoryReserveMiB * 1024)}))
        if [ "$agent_kib" -le 0 ]; then
          echo "the guest's RAM of $memtotal_kib KiB leaves nothing beyond the reserve of ${toString memoryReserveMiB} MiB" >&2
          exit 1
        fi
        systemctl set-property --runtime agent.slice MemoryMax=$((agent_kib * 1024))
        # /nix/.ro-store is the host's store itself, the lower layer of the
        # /nix/store overlay. The overlay holds its own reference to it, so
        # /nix/store keeps working under this empty root-only file system.
        # systemd counts the cover as part of the mount unit of
        # /nix/.ro-store, so only root stopping that unit removes it.
        mount -t tmpfs -o ro,nosuid,nodev,noexec,mode=0700 tmpfs /nix/.ro-store
        install -d -o ${agent.name} -g ${agent.group} -m 0700 ${agent.home}/.claude
        install -o ${agent.name} -g ${agent.group} -m 0600 ${claudeSettings} ${agent.home}/.claude/settings.json
        install -o ${agent.name} -g ${agent.group} -m 0600 /dev/null ${agent.home}/.claude.json
        jq --arg key "$CLAUDEVM_GUEST_KEY" --arg workspace "$CLAUDEVM_WORKSPACE" \
          '.customApiKeyResponses.approved = [$key, $key[-20:]]
           | .projects[$workspace].hasTrustDialogAccepted = true' \
          ${claudeState} > ${agent.home}/.claude.json
        # Claude Code refuses to run when /tmp/claude-<uid>, the directory it
        # keeps its temporary files in, belongs to another user. It is
        # created before the mounts, since the mount loop creates the missing
        # parents of a share's path owned by root.
        install -d -o ${agent.name} -g ${agent.group} -m 0700 /tmp/claude-${toString agent.uid}
        # The host enforces ro with virtiofsd --readonly; the ro mount
        # option makes the guest report it up front.
        while ${readMount}; do
          mkdir -p "$path"
          mount -t virtiofs -o "$mode" "$tag" "$path"
        done < /mnt/launch/mounts
      '';
    };

    # Drops the guest's unused dentries and inodes once it holds more than
    # half of the share budget in virtiofs inodes. The guest kernel keeps
    # unused inodes cached until memory runs short, which a scan of a large
    # tree does not cause; even a plain directory listing makes it look up
    # the entries it reads, as virtiofs reads directories with readdirplus.
    # A drop frees unused entries only, so it brings the count back below
    # the threshold only while what the guest pins stays below it: open
    # files, at most a quarter of the budget, plus the files kept open
    # behind mappings of store files, working directories and their
    # parents, which no limit bounds. In a booted guest a drop leaves about
    # 600 descriptors held on the store share, far below the threshold.
    #
    # The fuse_inode line of /proc/slabinfo counts the inodes of all shares
    # together, and its active objects include the free objects of per-CPU
    # slabs, so the count errs high. The line always exists: the cache has
    # a constructor, so the kernel never merges it into another. A write to
    # drop_caches with bit 2 frees the unused overlay dentries and the
    # virtiofs dentries and inodes they held, and a small residue can remain
    # until the next write; bit 4 keeps the kernel from logging every write
    # after the first.
    #
    # The check runs in one long-lived process that uses bash builtins only
    # and so starts no program: starting one opens files on the store, which
    # fails with ENFILE once the store's daemon has run out. For the same
    # reason a failure powers the VM off at once, without the shutdown
    # programs. It checks once a second and drops at every check above the
    # threshold, and it logs a drop that follows a check below the threshold
    # and the first check after a drop that is still above it.
    systemd.services.claudevm-share-inodes = {
      description = "Drop unused virtiofs inodes before a share runs out of host descriptors";
      wantedBy = [ "multi-user.target" ];
      before = [ "claude-session.service" ];
      unitConfig = {
        RequiresMountsFor = [ "/mnt/launch" ];
        FailureAction = "poweroff-immediate";
      };
      enableStrictShellChecks = true;
      serviceConfig = {
        Type = "exec";
        OOMScoreAdjust = -1000;
        StandardError = "journal+console";
      };
      script = ''
        enable -f ${pkgs.runtimeShellPackage}/lib/bash/sleep sleep
        # shellcheck disable=SC1091
        . /mnt/launch/env
        ${shareBudget}
        drop_above=$((share_fds / 2))
        # The last check found the count below the threshold, dropped after
        # a check below it, or found it still above it after a drop.
        state=below
        while true; do
          inodes=
          while read -r name active _; do
            if [ "$name" = fuse_inode ]; then
              inodes=$active
              break
            fi
          done < /proc/slabinfo
          : "''${inodes:?/proc/slabinfo has no fuse_inode line}"
          if [ "$inodes" -le "$drop_above" ]; then
            state=below
          else
            case $state in
              below)
                echo "$inodes virtiofs inodes exceed $drop_above; dropping the unused dentries and inodes"
                state=dropped
                ;;
              dropped)
                echo "$inodes virtiofs inodes still exceed $drop_above after a drop; dropping at every check until the count falls below"
                state=held
                ;;
            esac
            echo 6 > /proc/sys/vm/drop_caches
          fi
          sleep 1
        done
      '';
    };

    # The session and the Nix daemon, in whose cgroup the builds the session
    # asks for run, share one memory budget: together they hold no more
    # than MemoryMax, and either may use all of it. Files that their
    # processes write to the guest's RAM-backed file systems count against
    # it too. claudevm-home sets MemoryMax at boot to the guest's RAM less
    # memoryReserveMiB, before either unit starts. The guest has no swap,
    # so once the slice reaches MemoryMax the kernel can reclaim only its
    # page cache and then kills the process of the slice that holds the
    # most memory.
    systemd.slices.agent.description = "Claude Code session and Nix daemon";

    systemd.services.nix-daemon = {
      after = [ "claudevm-home.service" ];
      serviceConfig = {
        Slice = "agent.slice";
        # A build that the kernel kills for lack of memory fails alone; the
        # daemon goes on serving.
        OOMPolicy = "continue";
      };
    };

    # The journal is RAM outside agent.slice, which the session can fill
    # through logger and systemd-cat.
    services.journald.settings.Journal = {
      Storage = "volatile";
      RuntimeMaxUse = "${toString journalMaxMiB}M";
    };

    systemd.services.claude-session = {
      description = "Claude Code session on the VM console";
      requires = [ "claudevm-home.service" ];
      wants = [ "network-online.target" ];
      after = [ "claudevm-home.service" "network-online.target" ];
      unitConfig = {
        RequiresMountsFor = [ "/mnt/launch" ];
        # The end of the session is the end of the VM. Once the unit is
        # inactive or failed, PID 1 syncs and powers off with the reboot
        # system call without stopping any other unit, so nothing else
        # running in the guest delays it; for a failed unit it waits 5 s
        # first. Nothing in the guest needs an orderly shutdown: the root
        # file system lives in RAM, and virtiofsd-run serves the shares
        # without writeback caching, so a write to a shared directory has
        # reached the host when the write call returns.
        SuccessAction = "poweroff-immediate";
        FailureAction = "poweroff-immediate";
      };
      wantedBy = [ "multi-user.target" ];
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "idle";
        User = agent.name;
        Group = agent.group;
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/ttyS0";
        TTYReset = true;
        TTYVHangup = true;
        # "-" makes every end of the session a success, a non-zero exit
        # status or a fatal signal alike, which spares it the 5 s wait of
        # FailureAction.
        ExecStart = "-${lib.getExe claudeSession}";
        # When the session exits, the processes it leaves running get
        # SIGTERM and this long to exit before SIGKILL. A unit whose
        # processes need the SIGKILL fails.
        TimeoutStopSec = 3;
        Slice = "agent.slice";
        # systemd's default OOM policy, stop, ends a unit once the kernel
        # has killed any of its processes for lack of memory. continue
        # keeps the session, and with it the VM, running for as long as its
        # main process lives.
        OOMPolicy = "continue";
        # Every process of the session inherits both, so no program it runs
        # gains privileges, setuid or file capabilities notwithstanding.
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
      };
    };
  };
}

{ config, lib, pkgs, ... }:

let
  cfg = config.claudevm;
  agent = config.users.users.agent;
  agentGid = config.users.groups.${agent.group}.gid;

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
    # exits as soon as any daemon exits.
    microvm.binScripts.virtiofsd-run =
      let
        virtiofsShares = builtins.filter
          (share: share.proto == "virtiofs")
          config.microvm.shares;
      in
      lib.mkForce ''
        set -euo pipefail
        trap 'kill $(jobs -p) 2>/dev/null || true; wait' EXIT
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
            --thread-pool-size ${toString config.microvm.virtiofsd.threadPoolSize} \
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

    boot.kernel.sysctl = {
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
      description = "Prepare agent home, broker access and shared directories from the launch share";
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      unitConfig.RequiresMountsFor = [ "/mnt/launch" ];
      onFailure = [ "poweroff.target" ];
      path = [ pkgs.util-linux pkgs.nftables pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        . /mnt/launch/env
        : "''${CLAUDEVM_BROKER_PORT:?is not set in /mnt/launch/env}"
        : "''${CLAUDEVM_GUEST_KEY:?is not set in /mnt/launch/env}"
        : "''${CLAUDEVM_WORKSPACE:?is not set in /mnt/launch/env}"
        nft insert rule inet egress output \
          ip daddr 10.0.2.2 tcp dport "$CLAUDEVM_BROKER_PORT" accept
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
      };
    };
  };
}

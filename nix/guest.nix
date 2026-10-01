{ config, lib, pkgs, ... }:

let
  cfg = config.claudevm;
  agent = config.users.users.agent;
  agentGid = config.users.groups.${agent.group}.gid;

  # Relative share sources resolve against the runtime directory the
  # claudevm wrapper cds into before starting virtiofsd. There "workspace"
  # is a symlink to the host's working directory and "launch" is a plain
  # directory of per-invocation launch input. The trailing /. makes the
  # symlink an intermediate path component: virtiofsd opens the share root
  # with O_NOFOLLOW and rejects a bare symlink.
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
      tag = "workspace";
      source = "workspace/.";
      mountPoint = "/workspace";
      proto = "virtiofs";
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

  # The launch input "mounts" lists the extra mounts of a launch as
  # NUL-terminated tag, path, mode (ro or rw) triples. The host serves each
  # tag on the socket <tag>.sock and the guest mounts it at path, the same
  # absolute path the directory has on the host.
  readMount = ''IFS= read -r -d "" tag && IFS= read -r -d "" path && IFS= read -r -d "" mode'';

  # Emits the per-launch QEMU arguments: the VM size from CLAUDEVM_VCPU and
  # CLAUDEVM_MEM (MiB) and a vhost-user-fs device per extra mount. QEMU
  # applies the last -smp and -m it is given, so these override the baked
  # ones. The baked memory backend of NUMA node 0 has the fixed size
  # microvm.mem and the backends of all nodes must add up to -m, so the rest
  # of the requested RAM forms a second node. microvm.mem is therefore also
  # the smallest RAM a launch can have. Runs with the runtime directory as
  # working directory, like virtiofsd-run.
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

  claudeSession = pkgs.writeShellApplication {
    name = "claude-session";
    runtimeInputs = [
      pkgs.claude-code
      pkgs.coreutils
      pkgs.bashInteractive
    ];
    text = ''
      set -a
      # shellcheck disable=SC1091
      . /mnt/launch/env
      set +a
      if [ -n "''${ROWS:-}" ] && [ -n "''${COLS:-}" ]; then
        stty rows "$ROWS" cols "$COLS" || true
      fi
      mapfile -d "" -t args < /mnt/launch/claude-args
      case $CLAUDEVM_SESSION in
        claude) exec claude --dangerously-skip-permissions "''${args[@]}" ;;
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
    # replacement starts one virtiofsd per share and per extra mount
    # directly. Of the share options it honors socket, source, cache and
    # readOnly; posixAcl and extraArgs are not passed. It exits as soon as
    # any daemon exits.
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

    boot.kernelParams = [ "quiet" ];

    networking.useNetworkd = true;
    systemd.network.wait-online = {
      enable = true;
      anyInterface = true;
    };

    # slirp forwards guest traffic for 10.0.2.2 and fec0::2 to the host's
    # loopback interface. DHCP to the slirp server at 10.0.2.2 stays open.
    networking.nftables = {
      enable = true;
      tables.host-loopback = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy accept;
            ip daddr 10.0.2.2 udp dport 67 accept
            ip daddr 10.0.2.2 reject
            ip6 daddr fec0::2 reject
          }
        '';
      };
    };

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # virtiofsd translates this uid and the gid of the users group (100) to
    # the invoking host user's ids, so the host ids are free to differ.
    users.users.agent = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };

    environment.systemPackages = [
      pkgs.claude-code
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
      description = "Prepare agent home and extra mounts from the launch share";
      unitConfig.RequiresMountsFor = [ "/mnt/launch" ];
      onFailure = [ "poweroff.target" ];
      path = [ pkgs.util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        install -d -o ${agent.name} -g ${agent.group} -m 0700 /run/claudevm/upper
        mkdir -p /run/claudevm/work ${agent.home}/.claude
        mount -t overlay overlay \
          -o lowerdir=/mnt/launch/claude,upperdir=/run/claudevm/upper,workdir=/run/claudevm/work \
          ${agent.home}/.claude
        if [ -e /mnt/launch/claude.json ]; then
          install -o ${agent.name} -g ${agent.group} -m 0600 /mnt/launch/claude.json ${agent.home}/.claude.json
        fi
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
      unitConfig.RequiresMountsFor = [ "/workspace" "/mnt/launch" ];
      wantedBy = [ "multi-user.target" ];
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "idle";
        User = agent.name;
        Group = agent.group;
        WorkingDirectory = "/workspace";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/ttyS0";
        TTYReset = true;
        TTYVHangup = true;
        ExecStart = lib.getExe claudeSession;
        ExecStopPost = "+${config.systemd.package}/bin/systemctl poweroff";
      };
    };
  };
}

{ config, lib, pkgs, ... }:

let
  agent = config.users.users.agent;
  agentGid = config.users.groups.${agent.group}.gid;
  steps = config.claudevm.homeSteps;

  # The launch input "mounts" lists the host directories a launch shares,
  # the workspace first, as NUL-terminated tag, path, mode (ro or rw)
  # triples. The host serves each tag on the socket <tag>.sock and the guest
  # mounts it at path, the same absolute path the directory has on the host.
  readMount = ''IFS= read -r -d "" tag && IFS= read -r -d "" path && IFS= read -r -d "" mode'';

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

  launchEnv = ''
    # shellcheck disable=SC1091
    . /mnt/launch/env
    : "''${CLAUDEVM_BROKER_PORT:?is not set in /mnt/launch/env}"
    : "''${CLAUDEVM_GUEST_KEY:?is not set in /mnt/launch/env}"
    : "''${CLAUDEVM_WORKSPACE:?is not set in /mnt/launch/env}"
  '';

  brokerAccess = ''
    nft insert rule inet egress output \
      ip daddr 10.0.2.2 tcp dport "$CLAUDEVM_BROKER_PORT" accept
  '';

  forwardRegistration = ''
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
  '';

  gitIdentity = ''
    # The launch input "gitconfig" is a git config file that holds the
    # user.name and user.email with which git on the host commits in the
    # workspace, each only if the host sets it. As the agent's global
    # git config it gives commits made in the VM the same identity; the
    # config of the repository still takes precedence over it.
    install -o ${agent.name} -g ${agent.group} -m 0600 /mnt/launch/gitconfig ${agent.home}/.gitconfig
  '';

  claudeTmpDir = ''
    # Claude Code refuses to run when /tmp/claude-<uid>, the directory it
    # keeps its temporary files in, belongs to another user. It is
    # created before the mounts, since the mount loop creates the missing
    # parents of a share's path owned by root.
    install -d -o ${agent.name} -g ${agent.group} -m 0700 /tmp/claude-${toString agent.uid}
  '';

  shareMounts = ''
    # The host enforces a read-only share with virtiofsd --readonly, and
    # the guest mounts it read-only as well, so a write fails with EROFS
    # in the guest even if the host did not refuse it.
    while ${readMount}; do
      mkdir -p "$path"
      mount -t virtiofs -o "$mode" "$tag" "$path"
    done < /mnt/launch/mounts
  '';
in
{
  options.claudevm.prependForwardPath = lib.mkOption {
    type = lib.types.str;
    internal = true;
    readOnly = true;
    description = "Shell code that puts the bin directories of the forward_packages of the launch in front of PATH.";
  };

  config = {
    # The shares every launch has. Relative share sources resolve against the
    # runtime directory the claudevm wrapper cds into before starting
    # virtiofsd, where "launch" is a plain directory of per-invocation launch
    # input. The workspace and the other host directories of a launch come
    # from the launch input "mounts" instead.
    microvm.shares = [
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

    microvm.extraArgsScript = lib.getExe launchArgs;

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

    # The host enforces a read-only share with virtiofsd --readonly, and the
    # guest mounts it read-only as well, so a write fails with EROFS in the
    # guest even if the host did not refuse it. "ro" follows the options
    # that microvm.nix gives the mount, its "defaults" among them, as the
    # last of conflicting mount options wins.
    fileSystems = lib.listToAttrs (map
      (share: lib.nameValuePair share.mountPoint { options = lib.mkAfter [ "ro" ]; })
      (builtins.filter (share: share.readOnly) config.microvm.shares));

    # The launch input "forward-path" lists the bin directories of the
    # packages the host built for the launch as NUL-terminated store paths,
    # which the guest sees through the ro-store share. This puts them in front
    # of PATH in that order; an empty list leaves PATH unchanged.
    claudevm.prependForwardPath = ''
      PATH="$(${lib.getExe' pkgs.coreutils "tr"} '\0' : < /mnt/launch/forward-path)$PATH"
    '';

    # Login shells such as the debug shell reset PATH in
    # /etc/set-environment, which runs this last.
    environment.extraInit = lib.mkAfter config.claudevm.prependForwardPath;

    systemd.services.claudevm-home = {
      description = "Prepare agent home, the git identity, broker access, the open-file limit, the store ACL, the forward_packages registration, the agent memory limit, the store share's cover and shared directories from the launch share";
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
      script = lib.concatStrings [
        launchEnv
        steps.openFileLimit
        brokerAccess
        steps.storeAcl
        forwardRegistration
        steps.agentMemoryLimit
        steps.storeCover
        steps.claudeConfig
        gitIdentity
        claudeTmpDir
        shareMounts
      ];
    };
  };
}

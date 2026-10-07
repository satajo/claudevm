{ config, lib, pkgs, ... }:

let
  inputs = config.claudevm.inputs;
  steps = config.claudevm.homeSteps;
  agent = config.users.users.agent;
  agentGid = config.users.groups.${agent.group}.gid;

  # Emits the per-launch QEMU arguments: the VM size from CLAUDEVM_VCPU and
  # CLAUDEVM_MEM (MiB) and the devices of the shares input. QEMU applies the
  # last -smp and -m it is given, so these override the baked ones. The
  # baked memory backend of NUMA node 0 has the fixed size microvm.mem and
  # the backends of all nodes must add up to -m, so the rest of the
  # requested RAM forms a second node. microvm.mem is therefore also the
  # smallest RAM a launch can have. Runs with the runtime directory as
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
      ${inputs.shares.qemuDevices}
      echo "''${args[*]}"
    '';
  };
in
{
  options.claudevm.inputs = lib.mkOption {
    type = lib.types.raw;
    internal = true;
    readOnly = true;
    description = "The inputs of a launch, whose host halves the launcher runs.";
  };

  config = {
    claudevm.inputs = import ../inputs { inherit config lib pkgs; };

    # The launch directory. Relative share sources resolve against the
    # runtime directory the claudevm wrapper cds into before starting
    # virtiofsd, where "launch" is a plain directory with an entry per
    # input. The workspace and the other host directories of a launch come
    # from the shares input instead.
    microvm.shares = [
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
    # replacement starts one virtiofsd per share of microvm.shares and per
    # share of the shares input directly. Of the share options it honors
    # socket, source, cache and readOnly; posixAcl and extraArgs are not
    # passed. It exits as soon as any daemon exits. Each daemon runs
    # CLAUDEVM_SHARE_THREADS threads, in place of
    # microvm.virtiofsd.threadPoolSize, and may hold CLAUDEVM_SHARE_NOFILE
    # descriptors; the launcher sets both from the descriptor-budget input.
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
        ${inputs.shares.serveShares}
        wait -n
      '';

    # The host enforces a read-only share with virtiofsd --readonly, and the
    # guest mounts it read-only as well, so a write fails with EROFS in the
    # guest even if the host did not refuse it: the shares of the shares
    # input with the mode of their entry, and those of microvm.shares with
    # "ro". "ro" follows the options that microvm.nix gives the mount, its
    # "defaults" among them, as the last of conflicting mount options wins.
    fileSystems = lib.listToAttrs (map
      (share: lib.nameValuePair share.mountPoint { options = lib.mkAfter [ "ro" ]; })
      (builtins.filter (share: share.readOnly) config.microvm.shares));

    # Login shells such as the debug shell reset PATH in
    # /etc/set-environment, which runs this last.
    environment.extraInit = lib.mkAfter inputs.forwardPackages.login;

    systemd.services.claudevm-home = {
      description = "Prepare the guest and the agent's home for the session";
      # The setup of broker-access inserts a rule into the egress table,
      # which nftables.service creates.
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      unitConfig.RequiresMountsFor = [ "/mnt/launch" "/tmp" agent.home ];
      onFailure = [ "poweroff.target" ];
      path = [ pkgs.coreutils ];
      enableStrictShellChecks = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      # claudeConfig and claudeTmpDir write to the disk, through the
      # agent's home and /tmp. claudeTmpDir runs before the share mounts of
      # shares, which create the missing parents of a share's path owned by
      # root. claudeConfig runs before the inputs that build on what it
      # installs: shares and broker-access add to its ~/.claude.json, and
      # transcripts binds the session directory into its ~/.claude. The
      # setup of the inputs after shares runs with the shares mounted: no
      # share may overlap /nix, the agent's home, the disk or the launch
      # directory, and no setup step touches a path inside a share.
      script = lib.concatStrings ([
        steps.openFileLimit
        steps.storeAcl
        steps.agentMemoryLimit
        steps.storeCover
        steps.claudeConfig
        steps.claudeTmpDir
      ] ++ map (input: input.setup) inputs.ordered);
    };
  };
}

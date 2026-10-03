{ config, lib, pkgs, ... }:

let
  # The journal lives in RAM, outside agent.slice, and keeps at most this
  # many MiB.
  journalMaxMiB = 16;

  # The guest's RAM that agent.slice leaves to the rest of the guest, the
  # same at every launch size. At idle the kernel, PID 1 and the guest's
  # services hold about 100 MiB that they cannot reclaim, about half of it
  # kernel memory charged to no cgroup. The journal may add journalMaxMiB,
  # and the rest is headroom for their page cache and growth.
  memoryReserveMiB = 256;

  readFdBudget = config.claudevm.inputs.descriptorBudget.read;
in
{
  options.claudevm = {
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
    homeSteps = {
      openFileLimit = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        description = "Step of the claudevm-home script that limits the open files of the guest to its share of the share budget.";
      };
      agentMemoryLimit = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        description = "Step of the claudevm-home script that sets the memory limit of agent.slice.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = config.microvm.virtiofsd.package.version == "1.14.0";
        message = "claudevm.virtiofsdReservedFds is the descriptor reserve of virtiofsd 1.14.0; check it against virtiofsd ${config.microvm.virtiofsd.package.version} and update the version in this assertion";
      }
    ];

    claudevm.homeSteps = {
      openFileLimit = ''
        ${readFdBudget}
        # Processes without CAP_SYS_ADMIN, everything the session runs among
        # them, may hold a quarter of the share budget open. Root's files
        # count towards fs.file-max too, but only root may exceed it. The
        # files the kernel keeps open behind a mapping of a store file,
        # working directories and the parents of everything held pin inodes
        # on a share without counting. systemd raises fs.file-max to the
        # largest value at boot.
        file_max=$((share_fds / 4))
        echo "$file_max" > /proc/sys/fs/file-max
      '';

      agentMemoryLimit = ''
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
        ${config.systemd.package}/bin/systemctl set-property --runtime agent.slice MemoryMax=$((agent_kib * 1024))
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
        ${readFdBudget}
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
  };
}

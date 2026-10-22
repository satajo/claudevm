# The host descriptors that each share daemon lets the guest hold, derived
# from the host's hard limit of open files.
#
# Uses from the launcher: host_vcpu and quoted.
# Defines for the launcher: share_nofile, the descriptor limit of each
# virtiofsd and the soft limit of QEMU, and share_threads, the thread pool
# size of each virtiofsd.
#
# Besides the five fragments it provides read, which sets share_fds in the
# guest with bash builtins only.
{ config, lib, pkgs }:

{
  # virtiofsd holds a host descriptor for every inode of its share that the
  # guest holds and another for every file the guest has open. QEMU's user
  # networking holds a host socket for every guest connection, every ICMP
  # echo request and every guest UDP source port, the last two for up to
  # 240 s each; the guest's fs.file-max does not bound these, and once QEMU
  # has spent its limit, new guest connections fail until old ones expire.
  # Each virtiofsd gets the hard limit of open files as --rlimit-nofile and
  # QEMU as its soft limit, raised in the subshell that starts it. The
  # broker and everything else the launcher runs keep the soft limit
  # claudevm starts with, which bounds the broker's connections. Each
  # virtiofsd runs a thread per host CPU, keeps
  # claudevm.virtiofsdReservedFds descriptors and one per thread for itself
  # and answers the guest with ENFILE once the guest holds the rest,
  # share_fds. A booted guest holds about 2500 descriptors on the store
  # share; the VM requires a hard limit of at least 65536 so that this
  # stays a small part of share_fds.
  collect = ''
    share_nofile=$(ulimit -Hn)
    if ! [[ $share_nofile =~ ^[1-9][0-9]*$ ]]; then
      echo "claudevm: the hard limit of open files is $(quoted "$share_nofile"), not a number" >&2
      exit 1
    fi
    if [ "$share_nofile" -lt 65536 ]; then
      echo "claudevm: the hard limit of open files (ulimit -Hn) is $share_nofile; the VM requires at least 65536" >&2
      exit 1
    fi
    share_threads=$host_vcpu
    share_fds=$((share_nofile - ${toString config.claudevm.virtiofsdReservedFds} - share_threads))
  '';

  summary = "";

  # The entry holds share_fds as a NUL-terminated field.
  write = ''
    printf '%s\0' "$share_fds" > "$runtime/launch/descriptor-budget"
  '';

  setup = "";

  session = "";

  # Each virtiofsd lets the guest hold share_fds host descriptors: one for
  # every inode of its share that the guest kernel holds and one more for
  # every open file and directory. Once the guest holds them all, the daemon
  # answers every further open, and every lookup of an inode the guest does
  # not hold yet, with ENFILE; the host itself never runs out.
  read = ''
    if ! { IFS= read -r -d "" share_fds && ! IFS= read -r -d "" rest && [ -z "$rest" ]; } < /mnt/launch/descriptor-budget \
        || ! [[ $share_fds =~ ^[1-9][0-9]*$ ]]; then
      echo "/mnt/launch/descriptor-budget holds no positive integer" >&2
      exit 1
    fi
  '';
}

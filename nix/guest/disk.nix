{ config, lib, ... }:

let
  cfg = config.claudevm;

  # The guest's file data lives on the disk, under this mount point: the
  # store overlay's upper and work directories, the Nix daemon's build
  # directories, /tmp, /var/tmp and /home.
  mountPoint = "/mnt/disk";
  layout = {
    storeOverlay = "${mountPoint}/store-overlay";
    nixBuilds = "${mountPoint}/nix-builds";
    tmp = "${mountPoint}/tmp";
    varTmp = "${mountPoint}/var-tmp";
    home = "${mountPoint}/home";
  };
  minimumMiB = 1024;

  # udev links the disk at /dev/disk/by-id/virtio-<serial>.
  serial = "claudevm";
in
{
  options.claudevm = {
    disk = lib.mkOption {
      type = lib.types.addCheck lib.types.ints.positive (size: size >= minimumMiB);
      description = "Size in MiB of the disk of a launch whose claudevm.toml sets no disk; at least claudevm.diskMinimum.";
    };
    diskMinimum = lib.mkOption {
      type = lib.types.ints.positive;
      internal = true;
      readOnly = true;
      default = minimumMiB;
      description = "Smallest disk in MiB that a launch accepts.";
    };
    diskMountPoint = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = mountPoint;
      description = "Guest path at which the disk is mounted.";
    };
    # QEMU opens /dev/fdset/1 read-write and read-only, and finds the
    # descriptor for each in the set by its access mode.
    diskFds = {
      readWrite = lib.mkOption {
        type = lib.types.ints.unsigned;
        internal = true;
        readOnly = true;
        default = 3;
        description = "Descriptor on which the launcher starts the runner with the disk image open read-write.";
      };
      readOnly = lib.mkOption {
        type = lib.types.ints.unsigned;
        internal = true;
        readOnly = true;
        default = 4;
        description = "Descriptor on which the launcher starts the runner with the disk image open read-only.";
      };
    };
  };

  config = {
    claudevm.disk = 32768;

    # The launcher creates the disk as an empty sparse file for each
    # launch, so the guest formats it ext4 at every boot and never checks
    # it. Deleted files return their blocks to the host file: ext4 discards
    # them, and QEMU punches holes for the discards. errors=panic ends the
    # VM at the first error of the file system: the guest kernel's panic
    # resets the machine, at which QEMU exits. A write that fails on the
    # host, as when its file system is full, reaches the guest as an I/O
    # error: a failed metadata write is such an error at the next journal
    # handle, and data_err=abort makes a failed data write abort the
    # journal, so that the next handle fails too. Until that next handle,
    # which the next file creation, deletion, allocation or writeback of
    # new data starts, a write accepted into the page cache is lost with
    # the VM without an error; fsync reports it. nosuid and nodev carry
    # over to the bind mounts of /home, /tmp and /var/tmp.
    fileSystems.${mountPoint} = {
      device = "/dev/disk/by-id/virtio-${serial}";
      fsType = "ext4";
      autoFormat = true;
      neededForBoot = true;
      noCheck = true;
      options = [ "discard" "errors=panic" "data_err=abort" "nosuid" "nodev" ];
    };

    # The activation script creates the agent's home before stage 2 mounts
    # its file systems, so /home is mounted in the initrd.
    fileSystems."/home" = {
      device = layout.home;
      fsType = "none";
      options = [ "bind" ];
      neededForBoot = true;
      depends = [ mountPoint ];
    };

    # systemd creates the source directories, and its tmpfiles
    # configuration gives /tmp and /var/tmp mode 1777.
    fileSystems."/tmp" = {
      device = layout.tmp;
      fsType = "none";
      options = [ "bind" ];
    };
    fileSystems."/var/tmp" = {
      device = layout.varTmp;
      fsType = "none";
      options = [ "bind" ];
    };

    microvm.writableStoreOverlay = layout.storeOverlay;

    nix.settings.build-dir = layout.nixBuilds;

    # cache=unsafe keeps the guest's writes in the host's page cache and
    # ignores its flushes: the disk's content is discarded with the launch.
    # werror=report hands a failed write to the guest instead of pausing
    # the VM. format=raw keeps QEMU from interpreting a header the guest
    # wrote.
    microvm.qemu.extraArgs = [
      "-add-fd"
      "fd=${toString cfg.diskFds.readWrite},set=1,opaque=disk-rw"
      "-add-fd"
      "fd=${toString cfg.diskFds.readOnly},set=1,opaque=disk-ro"
      "-drive"
      "id=disk,if=none,format=raw,file=/dev/fdset/1,cache=unsafe,discard=unmap,werror=report,rerror=report"
      "-device"
      "virtio-blk-pci,drive=disk,serial=${serial},disable-legacy=on"
    ];
  };
}

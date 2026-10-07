# Runs the guest's claudevm-share-inodes script on the guest's kernel, with
# a FUSE mount standing in for the shares and a descriptor budget that the
# test sets.
{ testers, bindfs, guest }:

let
  shareInodes = guest.systemd.services.claudevm-share-inodes.serviceConfig.ExecStart;
in
testers.runNixOSTest {
  name = "claudevm-share-inodes";

  nodes.machine = {
    boot.kernelPackages = guest.boot.kernelPackages;
    boot.kernelModules = [ "fuse" ];
    environment.systemPackages = [ bindfs ];
    systemd.services.share-inodes.serviceConfig = {
      Type = "exec";
      ExecStart = shareInodes;
    };
  };

  testScript = ''
    from datetime import timedelta

    drop_slab = "awk '$1 == \"drop_slab\" { print $2 }' /proc/vmstat"

    def drop_slab_count():
        return int(machine.succeed(drop_slab))

    def start_with_budget(share_fds):
        machine.succeed(f"printf '%s\\0' {share_fds} > /mnt/launch/descriptor-budget")
        machine.succeed("systemctl start share-inodes")

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "mkdir -p /mnt/launch /srv/tree /mnt/fuse",
        "for i in $(seq 1 200); do touch /srv/tree/f$i; done",
        "bindfs /srv/tree /mnt/fuse",
        "ls -l /mnt/fuse > /dev/null",
    )

    with subtest("a count below the threshold drops nothing"):
        before = drop_slab_count()
        start_with_budget(1000000)
        machine.sleep(timedelta(seconds=3))
        machine.require_unit_state("share-inodes", "active")
        assert drop_slab_count() == before, "the script dropped below the threshold"
        machine.succeed("systemctl stop share-inodes")

    with subtest("a count above the threshold drops the unused inodes and keeps watching"):
        before = drop_slab_count()
        start_with_budget(2)
        machine.wait_until_succeeds(f"[ $({drop_slab}) -gt {before + 2} ]", timeout=timedelta(seconds=30))
        machine.require_unit_state("share-inodes", "active")
        machine.succeed("journalctl -u share-inodes --grep 'virtiofs inodes exceed 1; dropping'")
        machine.succeed("systemctl stop share-inodes")

    with subtest("the kernel logs none of the drops"):
        machine.fail("dmesg | grep 'drop_caches: 2'")
  '';
}

# Runs the claudevm launcher on a NixOS host VM with nested KVM, as the
# host user alice, and checks the VM's disk from both sides: the guest
# writes what it sees to files in its workspace, and the host measures
# the disk image that QEMU holds. Every launch runs claudevm shell with a
# FIFO as stdin, through which the host types the command that runs the
# scenario's guest script until the script reports that it started.
#
# The launcher cannot run in the build sandbox itself: the sandbox's
# /nix/store holds every store path as a mount of its own, virtiofsd
# announces each as a submount, and overlayfs refuses a lower layer with
# submounts, so the guest's /nix/store overlay fails. The host VM's
# /nix/store is a single file system.
{ testers, writeShellApplication, writeText, bash, coreutils, nix, util-linux, claudevm }:

let
  home = "/home/alice";
  disksDir = "${home}/claudevm/disks";
  mib = 1024 * 1024;

  # claudevm-scenario WORKSPACE [TMPFS_OPTIONS] launches claudevm shell
  # in WORKSPACE and writes its exit status to WORKSPACE/status. With
  # TMPFS_OPTIONS, the launch sees a tmpfs with those options on the
  # disks directory: mount(8) mounts only as root, so the tmpfs is
  # mounted as root of a user namespace, which then runs the launcher as
  # alice again, without capabilities.
  scenario = writeShellApplication {
    name = "claudevm-scenario";
    runtimeInputs = [ claudevm bash coreutils nix util-linux ];
    text = ''
      workspace=$1
      cd "$workspace"
      launch=(claudevm shell)
      if [ "$#" -eq 2 ]; then
        # shellcheck disable=SC2016 # the inner shell expands them
        launch=(
          unshare --user --map-root-user --mount -- bash -c '
            mount -t tmpfs -o "$1" tmpfs ${disksDir} &&
              exec unshare --user --map-user="$2" --map-group="$3" -- claudevm shell
          ' bash "$2" "$(id -u)" "$(id -g)"
        )
      fi
      mkfifo console-in
      "''${launch[@]}" < console-in > console.log 2>&1 &
      launcher=$!
      echo "$launcher" > launcher.pid
      # Once QEMU has exited, a write to the FIFO fails instead of ending
      # this script.
      trap "" PIPE
      exec 3> console-in
      # The serial console drops what arrives before the session opens it.
      while [ ! -e started ] && kill -0 "$launcher" 2> /dev/null; do
        echo "bash $workspace/guest.sh < /dev/null; exit" >&3 || true
        sleep 3
      done
      status=0
      wait "$launcher" || status=$?
      echo "$status" > status
    '';
  };

  # Prints the descriptor through which a process holds a deleted disk
  # image of alice's claudevm directory; fails when none does.
  heldDiskImage = writeShellApplication {
    name = "held-disk-image";
    text = ''
      for fd in /proc/[0-9]*/fd/*; do
        target=$(readlink "$fd" 2> /dev/null) || continue
        if [[ $target == ${disksDir}/disk.*" (deleted)" ]]; then
          echo "$fd"
          exit 0
        fi
      done
      exit 1
    '';
  };

  # Guest scripts run as agent in the debug shell. Each writes what it
  # observes to files of the workspace, which reach the host when the
  # write returns, and waits for files the host creates there.
  guestScript = name: body: writeText "claudevm-disk-test-${name}.sh" ''
    ws=$(dirname "$0")
    await() {
      until [ -e "$ws/$1" ]; do
        sleep 0.2
      done
    }
    touch "$ws/started"
    ${body}
  '';

  guestScripts = {
    disk = guestScript "disk" ''
      for path in /tmp /var/tmp /home; do
        echo "$path $(findmnt -no FSTYPE,SOURCE --mountpoint "$path")"
      done > "$ws/mounts"
      findmnt -no OPTIONS --mountpoint /nix/store > "$ws/store-options"
      stat -c %a /tmp /var/tmp > "$ws/tmp-modes"
      echo $(($(cat /sys/block/vda/size) * 512)) > "$ws/disk-bytes"
      stat -c %U ~/.claude/settings.json /tmp/claude-1000 > "$ws/owners"
      findmnt -no FSTYPE --mountpoint ~/.claude/projects > "$ws/projects-fstype"
      ls /nix/store > /dev/null 2> "$ws/store-listing"
      echo $? > "$ws/store-listing-status"

      stat -c '%a %U %G' /dev/vda > "$ws/vda-owner"
      head -c 1 /dev/vda > /dev/null 2> "$ws/vda-read"
      echo $? > "$ws/vda-read-status"

      while grep -qsx ext4lazyinit /proc/[0-9]*/comm; do
        sleep 1
      done
      touch "$ws/lazyinit-done"
      await go-fill
      head -c 512M /dev/urandom > /tmp/fill
      sync
      touch "$ws/filled"
      await go-delete
      rm /tmp/fill
      sync
      touch "$ws/deleted"

      await go-build
      bash_package=$(dirname "$(dirname "$(readlink -f "$(command -v bash)")")")
      coreutils_package=$(dirname "$(dirname "$(readlink -f "$(command -v head)")")")
      cat > "$ws/builder.sh" <<'EOF'
      mkdir "$out"
      while read -r line; do
        if [[ $line == *" /build "* ]]; then
          echo "$line"
        fi
      done < /proc/self/mountinfo > "$out/build-mount"
      head -c 256M /dev/urandom > "$out/data"
      EOF
      output=$(nix build --no-link --print-out-paths --impure --option substitute false --expr "
        derivation {
          name = \"claudevm-disk-test\";
          system = builtins.currentSystem;
          builder = builtins.storePath \"$bash_package\" + \"/bin/bash\";
          PATH = builtins.storePath \"$coreutils_package\" + \"/bin\";
          args = [ \"-c\" (builtins.readFile \"$ws/builder.sh\") ];
        }" 2> "$ws/build-log")
      echo $? > "$ws/build-status"
      cp "$output/build-mount" "$ws/build-mount"
      sync
      touch "$ws/built"
      await go-collect
      nix-store --delete "$output" > /dev/null 2> "$ws/collect-log"
      echo $? > "$ws/collect-status"
      sync
      touch "$ws/collected"
      await go-exit
    '';

    memory = guestScript "memory" ''
      cat /sys/fs/cgroup/agent.slice/memory.max > "$ws/memory-max"
      dd if=/dev/zero of=/tmp/data bs=1M count=2048 status=none
      echo $? > "$ws/tmp-write-status"
      mkdir -p ~/.cache
      dd if=/dev/zero of="$HOME/.cache/data" bs=1M count=1024 status=none
      echo $? > "$ws/home-write-status"
      cat /sys/fs/cgroup/agent.slice/memory.events > "$ws/memory-events"
    '';

    full = guestScript "full" ''
      dd if=/dev/zero of=/tmp/fill bs=1M status=none 2> "$ws/fill-error"
      echo $? > "$ws/fill-status"
      rm /tmp/fill
      echo data > /tmp/after
      echo $? > "$ws/tmp-after-status"
      echo data > ~/after
      echo $? > "$ws/home-after-status"
    '';

    wait = guestScript "wait" ''
      sleep infinity
    '';

    exit = guestScript "exit" "";

    hostFull = guestScript "host-full" ''
      touch "$ws/writing"
      dd if=/dev/zero of=/tmp/fill bs=1M count=1024 status=none
      sync
      sleep infinity
    '';
  };
in
testers.runNixOSTest {
  name = "claudevm-disk";

  nodes.host = {
    virtualisation = {
      qemu.options = [ "-cpu" "host" ];
      cores = 4;
      memorySize = 6144;
      diskSize = 8192;
    };
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    environment.systemPackages = [ claudevm heldDiskImage ];
  };

  testScript = ''
    import shlex
    from datetime import timedelta

    home = "${home}"
    disks_dir = "${disksDir}"
    mib = ${toString mib}

    def launch(name, config, guest_script, disks_tmpfs=None):
        ws = f"{home}/{name}"
        host.succeed(
            f"mkdir {ws}",
            f"printf '%s\\n' {shlex.quote(config)} > {ws}/claudevm.toml",
            f"cp {guest_script} {ws}/guest.sh",
            f"chown -R alice:users {ws}",
        )
        args = [ws]
        if disks_tmpfs:
            host.succeed(f"install -d -o alice -g users -m 0700 {disks_dir}")
            args.append(disks_tmpfs)
        host.succeed(
            f"systemd-run --unit={name} --uid=alice --gid=users --property=Type=exec "
            + f"${scenario}/bin/claudevm-scenario {shlex.join(args)}"
        )
        return ws

    def await_file(ws, name, timeout):
        host.wait_until_succeeds(f"test -e {ws}/{name}", timeout=timeout)

    def read(ws, name):
        return host.succeed(f"cat {ws}/{name}").strip()

    def signal(ws, name):
        host.succeed(f"touch {ws}/{name}")

    def launcher_status(ws, timeout=timedelta(minutes=5)):
        await_file(ws, "status", timeout)
        return int(read(ws, "status"))

    def console(ws):
        return host.succeed(f"cat {ws}/console.log")

    def allocated_mib():
        blocks, block_size = host.succeed('stat -L -c "%b %B" "$(held-disk-image)"').split()
        return int(blocks) * int(block_size) // mib

    def assert_no_leftovers():
        host.fail("pgrep -u alice -f 'microvm@claudevm|virtiofsd|claudevm-broker'")
        host.fail("held-disk-image")
        host.fail("ls -d /tmp/claudevm.*")
        assert host.succeed(f"ls -A {disks_dir}") == "", "the disks directory is not empty"

    def guest_file_data_lives_on_the_disk(ws):
        for line in read(ws, "mounts").splitlines():
            path, fstype, source = line.split()
            assert fstype == "ext4", f"{path} is {fstype}, not ext4"
            assert source.startswith("/dev/vda["), f"{path} comes from {source}, not /dev/vda"
        store_options = read(ws, "store-options")
        assert "upperdir=/sysroot/mnt/disk/store-overlay/store" in store_options.split(","), \
            f"the store overlay's options are {store_options}"
        assert read(ws, "tmp-modes").split() == ["1777", "1777"], "/tmp and /var/tmp are not 1777"
        assert int(read(ws, "disk-bytes")) == 32768 * mib, "the disk does not have the size of claudevm.toml"
        assert read(ws, "owners").split() == ["agent", "agent"], \
            "~/.claude/settings.json and /tmp/claude-1000 do not belong to agent"
        assert read(ws, "projects-fstype") == "virtiofs", "~/.claude/projects is not the session share"
        assert read(ws, "store-listing-status") != "0", "agent can list /nix/store"

    def the_agent_cannot_read_the_raw_disk(ws):
        assert read(ws, "vda-owner") == "660 root disk", f"/dev/vda is {read(ws, 'vda-owner')}"
        assert read(ws, "vda-read-status") != "0", "agent read /dev/vda"
        assert "Permission denied" in read(ws, "vda-read"), read(ws, "vda-read")

    def deleted_files_return_space_to_the_host_file(ws):
        await_file(ws, "lazyinit-done", timedelta(minutes=5))
        formatted = allocated_mib()
        assert formatted < 300, f"the formatted disk takes {formatted} MiB on the host"
        signal(ws, "go-fill")
        await_file(ws, "filled", timedelta(minutes=2))
        filled = allocated_mib()
        assert filled >= formatted + 512, f"512 MiB written grew the image from {formatted} to {filled} MiB"
        signal(ws, "go-delete")
        await_file(ws, "deleted", timedelta(minutes=2))
        host.wait_until_succeeds(
            f'[ $(($(stat -L -c "%b * %B" "$(held-disk-image)") / {mib})) -le {formatted + 32} ]',
            timeout=timedelta(seconds=30),
        )

    def builds_in_the_vm_use_the_disk(ws):
        before = allocated_mib()
        signal(ws, "go-build")
        await_file(ws, "built", timedelta(minutes=5))
        assert read(ws, "build-status") == "0", read(ws, "build-log")
        build_mount = read(ws, "build-mount")
        assert " - ext4 /dev/vda " in build_mount, f"the build ran in {build_mount}"
        built = allocated_mib()
        assert built >= before + 256, f"a 256 MiB output grew the image from {before} to {built} MiB"
        signal(ws, "go-collect")
        await_file(ws, "collected", timedelta(minutes=2))
        assert read(ws, "collect-status") == "0", read(ws, "collect-log")
        host.wait_until_succeeds(
            f'[ $(($(stat -L -c "%b * %B" "$(held-disk-image)") / {mib})) -le {before + 32} ]',
            timeout=timedelta(seconds=30),
        )

    def the_disk_is_gone_after_the_session(ws):
        signal(ws, "go-exit")
        assert launcher_status(ws) == 0, console(ws)
        assert_no_leftovers()

    def file_data_does_not_count_as_process_memory(ws):
        assert launcher_status(ws) == 0, console(ws)
        assert int(read(ws, "memory-max")) < 1024 * mib, "agent.slice may hold 1 GiB or more"
        assert read(ws, "tmp-write-status") == "0", "writing 2 GiB to /tmp failed"
        assert read(ws, "home-write-status") == "0", "writing 1 GiB to ~/.cache failed"
        events = dict(line.split() for line in read(ws, "memory-events").splitlines())
        assert events["oom_kill"] == "0", f"the kernel killed {events['oom_kill']} processes of agent.slice"

    def a_full_disk_gives_enospc_and_the_session_goes_on(ws):
        assert launcher_status(ws) == 0, console(ws)
        assert read(ws, "fill-status") != "0", "filling /tmp succeeded"
        assert "No space left on device" in read(ws, "fill-error"), read(ws, "fill-error")
        assert read(ws, "tmp-after-status") == "0", "writing to /tmp failed after the deletion"
        assert read(ws, "home-after-status") == "0", "writing to ~ failed after the deletion"

    def stale_empty_image_names_are_swept(ws):
        assert launcher_status(ws) == 0, console(ws)
        assert host.succeed(f"ls {disks_dir}").split() == ["disk.data0000", "disk.new0000"], \
            host.succeed(f"ls {disks_dir}")
        host.succeed(f"rm {disks_dir}/disk.data0000 {disks_dir}/disk.new0000")

    def a_signal_ends_the_launch_without_leftovers(ws):
        await_file(ws, "started", timedelta(minutes=2))
        host.succeed(f"kill -TERM $(cat {ws}/launcher.pid)")
        assert launcher_status(ws) == 143, console(ws)
        assert_no_leftovers()

    def signals_during_cleanup_do_not_cut_it_short(ws):
        await_file(ws, "started", timedelta(minutes=2))
        host.succeed(
            f"pid=$(cat {ws}/launcher.pid); kill -HUP $pid; sleep 0.05; kill -INT $pid; sleep 0.05; kill -TERM $pid"
        )
        assert launcher_status(ws) == 129, console(ws)
        assert_no_leftovers()

    def an_image_that_cannot_be_created_aborts_the_launch(ws):
        assert launcher_status(ws) == 1, console(ws)
        output = console(ws)
        assert "No space left on device" in output, output
        assert f"claudevm: cannot create the VM's disk image in {disks_dir}" in output, output
        assert "3008;start=" not in output, "the guest booted"
        assert_no_leftovers()

    def a_full_host_file_system_ends_the_vm(ws):
        await_file(ws, "writing", timedelta(minutes=2))
        assert launcher_status(ws, timedelta(seconds=60)) == 0, console(ws)
        output = console(ws)
        assert "EXT4-fs error" in output, output
        assert "Kernel panic" in output, output
        assert_no_leftovers()

    def a_failed_format_powers_the_vm_off(ws):
        assert launcher_status(ws, timedelta(seconds=150)) == 0, console(ws)
        output = console(ws)
        assert "Dependency failed for" in output and "/sysroot/mnt/disk" in output, output
        assert_no_leftovers()

    host.wait_for_unit("multi-user.target")
    host.succeed(
        f"mkdir -m 0700 {home}/claudevm",
        f"printf 'sk-ant-oat-test\\n' > {home}/claudevm/token",
        f"chmod 0600 {home}/claudevm/token",
        f"chown -R alice:users {home}/claudevm",
    )

    ws = launch("disk", "disk = 32768", "${guestScripts.disk}")
    await_file(ws, "lazyinit-done", timedelta(minutes=5))
    with subtest("guest_file_data_lives_on_the_disk"):
        guest_file_data_lives_on_the_disk(ws)
    with subtest("the_agent_cannot_read_the_raw_disk"):
        the_agent_cannot_read_the_raw_disk(ws)
    with subtest("deleted_files_return_space_to_the_host_file"):
        deleted_files_return_space_to_the_host_file(ws)
    with subtest("builds_in_the_vm_use_the_disk"):
        builds_in_the_vm_use_the_disk(ws)
    with subtest("the_disk_is_gone_after_the_session"):
        the_disk_is_gone_after_the_session(ws)

    with subtest("file_data_does_not_count_as_process_memory"):
        file_data_does_not_count_as_process_memory(
            launch("memory", "memory = 1024\ndisk = 4096", "${guestScripts.memory}")
        )

    with subtest("a_full_disk_gives_enospc_and_the_session_goes_on"):
        a_full_disk_gives_enospc_and_the_session_goes_on(
            launch("full", "memory = 1024\ndisk = 1024", "${guestScripts.full}")
        )

    with subtest("stale_empty_image_names_are_swept"):
        host.succeed(
            f"install -d -o alice -g users -m 0700 {disks_dir}",
            f"touch -d '-2 minutes' {disks_dir}/disk.old0000",
            f"touch {disks_dir}/disk.new0000",
            f"echo data > {disks_dir}/disk.data0000",
            f"chown alice:users {disks_dir}/disk.*",
        )
        stale_empty_image_names_are_swept(
            launch("sweep", "memory = 1024\ndisk = 1024", "${guestScripts.exit}")
        )

    with subtest("a_signal_ends_the_launch_without_leftovers"):
        a_signal_ends_the_launch_without_leftovers(
            launch("term", "memory = 1024\ndisk = 1024", "${guestScripts.wait}")
        )

    with subtest("signals_during_cleanup_do_not_cut_it_short"):
        signals_during_cleanup_do_not_cut_it_short(
            launch("signals", "memory = 1024\ndisk = 1024", "${guestScripts.wait}")
        )

    with subtest("an_image_that_cannot_be_created_aborts_the_launch"):
        an_image_that_cannot_be_created_aborts_the_launch(
            launch("no-inode", "memory = 1024\ndisk = 1024", "${guestScripts.exit}", "size=1m,nr_inodes=1")
        )

    with subtest("a_full_host_file_system_ends_the_vm"):
        a_full_host_file_system_ends_the_vm(
            launch("host-full", "memory = 1024\ndisk = 4096", "${guestScripts.hostFull}", "size=256m")
        )

    with subtest("a_failed_format_powers_the_vm_off"):
        a_failed_format_powers_the_vm_off(
            launch("no-format", "memory = 1024\ndisk = 4096", "${guestScripts.exit}", "size=64k")
        )
  '';
}

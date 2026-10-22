# Runs the claudevm launcher on a NixOS host VM with nested KVM, as the
# host user alice, on a pty whose size the test changes during the launch,
# and checks the size of the console that the guest's session runs on.
# The launch runs claudevm shell, through which the host types the
# command that runs the guest script until the script reports that it
# started. The launcher cannot run in the build sandbox itself, for the
# reason that disk-test.nix gives.
{ testers, writeShellApplication, writeText, bash, coreutils, nix, util-linux, claudevm }:

let
  home = "/home/alice";

  # claudevm-terminal-scenario WORKSPACE launches claudevm shell in
  # WORKSPACE on a pty of script(1) that starts at 40 rows and 100
  # columns, and writes the launcher's PID to WORKSPACE/launcher.pid, the
  # pty to WORKSPACE/tty and the launcher's exit status to
  # WORKSPACE/status.
  scenario = writeShellApplication {
    name = "claudevm-terminal-scenario";
    runtimeInputs = [ claudevm coreutils nix util-linux ];
    text = ''
      workspace=$1
      cd "$workspace"
      mkfifo console-in
      # shellcheck disable=SC2016 # the shell of script expands them
      SHELL=${bash}/bin/bash script --quiet --flush --return \
        --command 'echo "$$" > launcher.pid && tty > tty && stty rows 40 cols 100 && exec claudevm shell' \
        /dev/null < console-in > console.log 2>&1 &
      script_pid=$!
      # Once QEMU has exited, a write to the FIFO fails instead of ending
      # this script.
      trap "" PIPE
      exec 3> console-in
      # The serial console drops what arrives before the session opens it.
      while [ ! -e started ] && kill -0 "$script_pid" 2> /dev/null; do
        echo "bash $workspace/guest.sh < /dev/null; exit" >&3 || true
        sleep 3
      done
      status=0
      wait "$script_pid" || status=$?
      echo "$status" > status
    '';
  };

  # Runs as agent in the debug shell, as a job of its own in the
  # foreground of the console. It writes what it observes to files of the
  # workspace, the console's size every 0.2 s, until the host creates
  # go-exit.
  guestScript = writeText "claudevm-terminal-test.sh" ''
    ws=$(dirname "$0")
    trap 'touch "$ws/winch"' WINCH
    port=$(readlink -f /dev/virtio-ports/claudevm.winsize)
    stat -c '%a %U %G' "$port" > "$ws/port-owner"
    : 2> "$ws/port-write" > "$port"
    echo $? > "$ws/port-write-status"
    cut -d " " -f 1 /proc/modules > "$ws/modules"
    touch "$ws/started"
    until [ -e "$ws/go-exit" ]; do
      stty size < /dev/tty > "$ws/size.new"
      mv "$ws/size.new" "$ws/size"
      sleep 0.2
    done
  '';
in
testers.runNixOSTest {
  name = "claudevm-terminal";

  nodes.host = {
    virtualisation = {
      qemu.options = [ "-cpu" "host" ];
      cores = 2;
      memorySize = 3072;
      diskSize = 4096;
    };
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    environment.systemPackages = [ claudevm ];
  };

  testScript = ''
    from datetime import timedelta

    home = "${home}"
    ws = f"{home}/terminal"

    def read(name):
        return host.succeed(f"cat {ws}/{name}").strip()

    def await_file(name, timeout):
        host.wait_until_succeeds(f"test -e {ws}/{name}", timeout=timeout)

    def console():
        return host.succeed(f"cat {ws}/console.log")

    def resize(rows, cols):
        host.succeed(f"stty -F {read('tty')} rows {rows} cols {cols}")

    def await_guest_size(rows, cols):
        host.wait_until_succeeds(f"grep -qx '{rows} {cols}' {ws}/size", timeout=timedelta(seconds=10))

    def the_port_is_read_only_for_agent():
        assert read("port-owner") == "400 agent root", f"the port is {read('port-owner')}"
        assert read("port-write-status") != "0", "agent wrote to the port"
        assert "Permission denied" in read("port-write"), read("port-write")
        assert "virtio_console" in read("modules").split(), "virtio_console is not loaded"

    def the_session_gets_the_last_size_sent_during_the_boot():
        await_guest_size(45, 110)

    def a_resize_during_the_session_reaches_its_console_and_foreground_job():
        host.succeed(f"rm -f {ws}/winch")
        resize(50, 120)
        await_guest_size(50, 120)
        await_file("winch", timedelta(seconds=10))
        host.succeed(f"kill -0 $(cat {ws}/launcher.pid)")

    def resizes_while_the_vm_powers_off_leave_the_exit_status():
        pid = read("launcher.pid")
        host.succeed(f"(while kill -WINCH {pid}; do sleep 0.01; done) > /dev/null 2>&1 &")
        host.succeed(f"touch {ws}/go-exit")
        await_file("status", timedelta(minutes=2))
        assert read("status") == "0", console()
        host.fail("pgrep -u alice -f 'microvm@claudevm|virtiofsd|claudevm-broker'")
        host.fail("ls -d /tmp/claudevm.*")

    host.wait_for_unit("multi-user.target")
    host.succeed(
        f"mkdir -m 0700 {home}/claudevm",
        f"printf 'sk-ant-oat-test\\n' > {home}/claudevm/token",
        f"chmod 0600 {home}/claudevm/token",
        f"mkdir {ws}",
        f"printf 'memory = 1024\\ndisk = 1024\\n' > {ws}/claudevm.toml",
        f"cp ${guestScript} {ws}/guest.sh",
        f"chown -R alice:users {home}/claudevm {ws}",
    )
    host.succeed(
        "systemd-run --unit=terminal --uid=alice --gid=users --property=Type=exec "
        + f"${scenario}/bin/claudevm-terminal-scenario {ws}"
    )
    # QEMU holds the port's FIFO from its start, while the guest opens the
    # port only once it starts the session.
    host.wait_until_succeeds(
        f"pgrep -u alice -f microvm@claudevm || test -e {ws}/status", timeout=timedelta(minutes=1)
    )
    assert host.execute(f"test -e {ws}/status")[0] != 0, console()
    resize(30, 90)
    resize(45, 110)
    await_file("started", timedelta(minutes=2))

    with subtest("the_port_is_read_only_for_agent"):
        the_port_is_read_only_for_agent()
    with subtest("the_session_gets_the_last_size_sent_during_the_boot"):
        the_session_gets_the_last_size_sent_during_the_boot()
    with subtest("a_resize_during_the_session_reaches_its_console_and_foreground_job"):
        a_resize_during_the_session_reaches_its_console_and_foreground_job()
    with subtest("resizes_while_the_vm_powers_off_leave_the_exit_status"):
        resizes_while_the_vm_powers_off_leave_the_exit_status()
  '';
}

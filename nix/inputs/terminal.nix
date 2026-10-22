# The host terminal's TERM and window size, which the session's terminal
# takes on. The serial console carries no window size, so the size travels
# over a virtio-serial port that the guest can only read: the launcher
# sends it as it writes the launch directory and again on every SIGWINCH,
# and the session applies each size to the console as it arrives.
#
# Uses from the launcher: runtime and quoted.
# Defines for the launcher: send_winsize, which the launcher's WINCH trap
# calls.
#
# Besides the five fragments it provides portName, the name of the port,
# portPath, the link to its node in the guest, and qemuDevices, the QEMU
# arguments of the port.
{ config, lib, pkgs }:

let
  portName = "claudevm.winsize";
  portPath = "/dev/virtio-ports/${portName}";
  stty = lib.getExe' pkgs.coreutils "stty";
in
{
  inherit portName portPath;

  # send_winsize writes a line to the port: the rows and columns of the
  # launcher's terminal, or nothing when it has no window size. The write
  # never blocks: a line shorter than PIPE_BUF enters the FIFO whole or
  # not at all, and while the guest leaves the port unread and the FIFO
  # is full, the line is dropped. Until the write has created the FIFO, dd
  # creates no file in its place and fails.
  collect = ''
    terminal_type=''${TERM:-xterm-256color}

    send_winsize() {
      local size
      size=$(stty size 2>/dev/null) || size=
      dd of="$runtime/winsize.in" oflag=nonblock conv=nocreat,notrunc status=none <<< "$size"
    }
  '';

  summary = "";

  # The entry holds TERM as a NUL-terminated field. The port carries one
  # line per size, and this sends the first, so the port always has one.
  # QEMU's pipe chardev reads the guest's input from winsize.in, but only
  # while the guest has the port open, and writes the guest's output to
  # winsize.out, which nothing reads. The launcher holds winsize.in open
  # for reading and writing until it exits, so that the FIFO keeps the
  # sizes sent before QEMU opens it.
  write = ''
    printf '%s\0' "$terminal_type" > "$runtime/launch/terminal"
    mkfifo -m 0600 "$runtime/winsize.in" "$runtime/winsize.out"
    # shellcheck disable=SC2034 # the descriptor only holds the FIFO open
    exec {winsize_fd}<>"$runtime/winsize.in"
    if ! send_winsize; then
      echo "claudevm: cannot write the terminal size to $(quoted "$runtime/winsize.in")" >&2
      exit 1
    fi
  '';

  setup = "";

  # The first size applies before the exec, so that the session starts at
  # it, and every later one through a reader that runs alongside the
  # session. Both read through one descriptor of the port, as the kernel
  # discards what a port holds once its last descriptor closes. A size
  # applies to the console, which every program of the session shares;
  # an empty line applies nothing.
  session = ''
    if ! { IFS= read -r -d "" terminal_type && ! IFS= read -r -d "" rest && [ -z "$rest" ]; } < /mnt/launch/terminal \
        || [ -z "$terminal_type" ]; then
      echo "/mnt/launch/terminal holds no TERM" >&2
      exit 1
    fi
    export TERM=$terminal_type

    if ! exec {winsize_fd}<${portPath}; then
      echo "cannot open ${portPath}, the port of the terminal size" >&2
      exit 1
    fi
    exec {console_fd}<&0
    apply_winsize() {
      if [[ $1 =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        ${stty} rows "''${BASH_REMATCH[1]}" cols "''${BASH_REMATCH[2]}" <&"$console_fd" || true
      fi
    }
    if ! IFS= read -r size <&"$winsize_fd"; then
      echo "${portPath} ends before the first terminal size" >&2
      exit 1
    fi
    apply_winsize "$size"
    (
      while IFS= read -r size <&"$winsize_fd"; do
        apply_winsize "$size"
      done
    ) &
    exec {winsize_fd}<&- {console_fd}<&-
  '';

  # Appends the port to the array args. Runs with the runtime directory as
  # working directory, like virtiofsd-run.
  qemuDevices = ''
    args+=(
      -chardev "pipe,id=winsize,path=winsize"
      -device "virtio-serial-pci,id=virtio-serial"
      -device "virtserialport,chardev=winsize,name=${portName}"
    )
  '';
}

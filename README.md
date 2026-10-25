# claudevm

Runs Claude Code with `--dangerously-skip-permissions` in an ephemeral QEMU
microVM (microvm.nix). The VM can write the current directory, the extra
directories `claudevm.toml` marks writable and the session directory that
keeps its transcripts; it can read the host nix store, the read-only extra
directories and the plugin directories `claudevm.toml` lists; nothing else
on the host filesystem is shared. Claude Code in the VM starts from the
image's own defaults and gets nothing from `~/.claude`. Your login token
stays on the host, behind a broker that the VM reaches with a per-session
dummy key. When the session ends the VM powers off and all its state
outside the shared directories is gone.

## Usage

```
nix run /path/to/claudevm -- login                         # store your token, once
cd ~/projects/some-repo
nix run /path/to/claudevm -- init                          # write ./claudevm.toml
nix run /path/to/claudevm -- launch                        # start Claude Code
nix run /path/to/claudevm -- launch "summarize this repo"  # arguments go to claude
```

To install `claudevm`, use `nix profile install /path/to/claudevm`, or add
the flake as an input and its `packages.x86_64-linux.default` to your
packages. The commands are then `claudevm launch`, `claudevm shell`,
`claudevm init`, `claudevm login` and `claudevm help`, which prints the
help, a line for each command, to stdout.

`claudevm launch` takes what `claude` takes: every argument after `launch`
goes as given to the Claude Code running in the VM, also one that is the
name of a claudevm command, such as `claudevm launch help`. The other
commands take no arguments. Without a command, with an unknown one or with
arguments to a command that takes none, `claudevm` prints the problem and
the help to stderr, does nothing else and exits with status 1.

The messages of `claudevm` and of the broker show each path and value that
comes from outside them, from the command line, the environment,
`claudevm.toml`, the file system, the git config, a request of the guest
or a response of the upstream API, in single quotes. `claudevm` relays the
errors of `toml2json` and, after a failed launch, the logs of virtiofsd
and the broker line by line, each line prefixed with its source. In all
of these a backslash appears doubled, and each character that the locale
does not count as printable, such as an escape character, or byte that
forms no character appears as the escape of its code, `\xHH`, `\uHHHH` or
`\UHHHHHHHH`, so that none of this text can control the terminal. The VM's
console, which carries the session, and the tools that `claudevm` runs
in the foreground, such as `nix build` for `forward_packages`, `git` and
`claude setup-token`, write to the terminal as they are.

Boot waits for the guest network and takes about ten seconds. When Claude
Code exits, the VM powers off and `claudevm` cleans up; a guest mount that
fails at any stage of the boot, the format and mount of the VM's disk
included, also powers it off. Processes that Claude Code leaves running get
SIGTERM and three seconds to exit; any still running then are killed, and
the VM powers off five seconds later. Nothing else in the VM delays the
power-off but the kernel writing out the file data it still caches for the
VM's disk, which its dirty-page limit bounds. Every write to a shared
directory that a process in the VM completed has reached the host before
the power-off; a file that a killed process was still writing stays as far
as it got. SIGINT, SIGHUP or SIGTERM stops QEMU, virtiofsd and the broker.

- `claudevm shell` gives a debug shell instead of Claude Code, and takes no
  arguments. `claude` works in it with the same API access as the session.
- The guest boots quietly: kernel and firmware messages stay off the console
  so that the launch output above them remains readable.
- The session's terminal follows the size of the host terminal window,
  which reaches the VM over a virtio-serial port that the VM can only
  read; a resize before the VM has started the session applies when it
  does. Host environment variables other than `TERM` stay out.
- The exit status of `claudevm launch` and `claudevm shell` is QEMU's, not
  Claude Code's; 1 if a launch check fails, a `forward_packages` build
  fails, the disks directory is a symlink or cannot be created or set to
  mode 0700, the VM's disk image cannot be created, opened, unnamed or
  sized, or virtiofsd or the broker dies mid-session; 129/130/143 on
  SIGHUP/SIGINT/SIGTERM, also when more signals follow during the cleanup.

### Token

Every launch requires a token in the claudevm directory, `~/claudevm/token`,
and refuses to start without one. The environment variable `CLAUDEVM_HOME`
puts the claudevm directory elsewhere; it must be an absolute path, and
`claudevm launch`, `claudevm shell` and `claudevm login` refuse to run with
a relative or empty one. `claudevm login` stores the token:

- On a terminal it runs `claude setup-token` on the host, which signs you in
  through the browser and prints a long-lived OAuth token, and then asks you
  to paste that token; the input is hidden.
- Otherwise it reads the token as one line from stdin and runs nothing, for
  example `claudevm login < token.txt`.
- The token must start with `sk-ant-oat` and consist of printable ASCII
  without whitespace, as the one `claude setup-token` prints does. API keys
  (`sk-ant-api...`) are refused. The token replaces any stored token and is
  written with mode 0600 into a directory with mode 0700.
- A launch refuses a token file that it cannot read or that grants group or
  other any access.

The token is never copied into the VM. Each launch starts a broker on the
host loopback and gives the guest only a random API key made for that
session. Claude Code in the guest sends its API requests to the broker,
which accepts those that carry the session key, swaps the key for the token
and passes them on to `api.anthropic.com`.

### Sessions

The host keeps the transcripts of every session in the claudevm directory,
in a session directory of its own per launch:

```
~/claudevm/
  token
  disks/                                  the VM's disk while a launch runs;
                                          normally empty, see Disk below
  sessions/
    2026-10-03T14-22-05Z-some-repo/       one per launch
      -home-you-projects-some-repo/       written by Claude Code from here down
        <id>.jsonl
        <id>/subagents/agent-<id>.jsonl, agent-<id>.meta.json
        <id>/tool-results/...
```

- A session directory is named after the UTC time the launch starts and
  the workspace's name, cut to its first 200 bytes, with `-2`, `-3` and so
  on appended while the name is taken. The launch summary shows it on its
  `session` line. `sessions` and every session directory are created with
  mode 0700, and every launch sets `sessions` to 0700 again. The VM owns
  its session directory and can change its mode, so `sessions` is what
  keeps the transcripts private.
- The guest sees its session directory read-write as the agent's
  `~/.claude/projects`, where Claude Code writes as it does on the host: its
  own JSONL transcripts, one file per conversation and one per subagent.
  Files reach the host as they are written and are owned by you there.
- The VM sees its own launch's session directory and nothing else of the
  claudevm directory: `claudevm` refuses a workspace, mount or plugin
  directory that lies inside the claudevm directory, as it refuses one that
  contains it, and a launch whose runtime directory, `$XDG_RUNTIME_DIR` or
  else `/tmp`, lies inside it.
- `claudevm` never deletes a session directory that holds anything. One
  that is still empty when `claudevm` exits, as after a `claudevm shell`
  that ran no `claude` or a launch that failed before the VM started, is
  removed; `sessions` itself stays. Old sessions are yours to remove.
- Each launch starts with an empty `~/.claude/projects`, so
  `claude --resume` in the VM finds only the conversations of that launch.
- The guest writes the session directory, so treat its content with the
  same caution as the workspace: a transcript holds whatever the agent read
  and wrote, prompt injections included, and a session directory can hold
  any file the VM put there.

## Configuration

Every start of the VM requires a `claudevm.toml` in the working directory.
`claudevm init` writes one with the defaults and refuses to overwrite an
existing file. `claudevm` reads it once at launch, so edits made during a
session apply from the next launch. Every key is optional:

```toml
vcpu = 4          # default 4, clamped to 1..host CPUs
memory = 4096     # MiB, default 4096, clamped to 512..host MemTotal
disk = 32768      # MiB, default 32768, at least 1024
forward_packages = ["nixpkgs#ripgrep", ".#mytool", "~/code/tool#cli"]
plugin_mounts = ["~/code/some-plugin", "/opt/claude-plugins/review"]

[[mounts]]        # one table per extra host directory
path = "~/data"   # absolute, or starting with ~/
writable = false  # default false: read-only
```

- Unknown keys, wrong types, values that are not positive integers, a
  `disk` below 1024 and empty `forward_packages` or `plugin_mounts` entries
  are errors, reported before anything starts. `disk` is never clamped: no
  host value bounds it. `graphics` and `resolution` are reserved and
  rejected as not implemented yet.
- A clamped value is shown as `(clamped from N)`. `memory = 2048` launches
  with 2047 MiB, because QEMU's microvm machine hangs at boot with exactly
  2 GiB.
- A mount appears in the guest at its host path with symlinks resolved.
  Read-only mounts are enforced by virtiofsd on the host and mounted
  read-only in the guest. Files written to a writable mount are owned by
  you on the host.
- `claudevm` refuses a mount path that does not exist, is not a directory,
  is or contains `$HOME` (directories under it are fine), contains
  `~/.claude`, `~/.claude.json`, the token file or the claudevm directory,
  lies inside `~/.claude` or the claudevm directory, contains a directory
  the guest system needs, such as `/etc`, `/tmp` or `/var` (directories
  under them are fine), or overlaps the workspace, `/nix`, a guest path the
  VM uses (`/mnt/launch`, `/mnt/disk`, `/home/agent`) or another mount.
- `forward_packages` puts programs on the agent's PATH. Each entry is a nix
  flake installable, passed as written to `nix build` on the host except
  that a leading `~/` is expanded, so `ripgrep` alone fails where
  `nixpkgs#ripgrep` works. Relative references such as `.#mytool` resolve
  against the workspace. The image itself has git, python3, jq, file, zip,
  unzip and make besides the base system's coreutils, grep, sed, awk, find,
  diff, tar, curl and perl, and Claude Code brings ripgrep.
- The builds run at launch, before the VM starts, with your nix settings
  and under nix's normal build sandbox. The first build of an entry may
  need network access and take a while; later launches reuse what is already
  in the host store. A failed build aborts the launch with nix's error.
- Every `bin` directory among the outputs `nix build` produces for an entry
  goes on the agent's PATH, ahead of the rest of PATH and in the order
  listed; an entry without one is an error. The VM reads them through its
  share of the host nix store and downloads nothing. The built outputs and
  everything they reference are valid to the Nix in the VM, and garbage
  collection keeps them, in the VM and on the host, until the session
  ends.
- `plugin_mounts` lists host plugin directories for the session's Claude
  Code. Each entry is a path written like a mount path, absolute or starting
  with `~/`, and names a directory that contains
  `.claude-plugin/plugin.json`; the launch fails on one that does not. The
  directory is shared read-only at its host path, with symlinks resolved and
  the same refusals as a mount, and Claude Code loads the plugins in the
  order listed, each with `--plugin-dir`. A directory inside the workspace
  or a mount is already visible at its path, so it gets no share of its own
  and keeps that share's mode; entries must not overlap one another.
- The plugins reach the Claude Code that the session starts. `claude` run by
  hand in `claudevm shell` loads them only when given `--plugin-dir` itself.
- A plugin shipped inside the repository needs no mount: Claude Code loads a
  plugin placed at `.claude/skills/<name>/` with its own
  `.claude-plugin/plugin.json`. It does so only in a trusted workspace, and
  the image's defaults trust the workspace.
- `claudevm.toml` lives in the workspace, so it is visible and editable
  inside the VM by design; after a session that changed it, `claudevm`
  prints a NOTICE. Every launch prints the effective configuration
  after the builds and before the VM starts: the workspace, each mount with
  `ro` or `rw`, the session directory, one `plugin` line per
  `plugin_mounts` entry, with `ro` when the entry has a share of its own,
  each `forward_packages` entry, the `user.name` and `user.email` that git
  in the VM gets, the broker's port and token file, vcpu, memory and disk.

## What the VM can and cannot do

```
Host                            Guest
----                            -----
$PWD                rw   --->   same path
[[mounts]] dirs     ro   --->   same path             rw with writable = true
session directory   rw   --->   ~/.claude/projects    and the same path
plugin_mounts dirs  ro   --->   same path
forward_packages    built       their bin dirs first on PATH
git identity        copied      user.name and user.email, nothing else of
                                your git config
token               brokered    the guest holds a per-session dummy key
TERM, window size   copied      applied once at launch
ulimit -Hn          derived     bounds the files the guest holds open on a
                                share
launch arguments    passed      to claude, as given
/nix/store          ro   --->   /nix/store            not listable; rw overlay
                                                      on the VM's disk
~/claudevm/disks    created     the VM's disk         /tmp, /var/tmp, /home, the
                                                      store's rw overlay and nix
                                                      build dirs
~/.claude           not shared
~/.claude.json      not shared
rest of ~/claudevm  not shared
host loopback       blocked except the broker's port and DNS
LAN                 blocked except DNS, as are CGNAT, link-local, multicast
host's resolver     DNS through 10.0.2.3, which QEMU forwards to it
internet            outbound over IPv4 only, nothing inbound
everything else     not shared
```

- Paths: every shared directory, the workspace included, appears in the
  guest where it is on the host, at its path with symlinks resolved, so
  absolute paths and symlinks between shared directories keep their meaning
  in the VM. The session starts in the workspace.
- Workspace: shared read-write over virtiofs, live in both directions. Files
  the agent creates are owned by you on the host. `claudevm` refuses a
  workspace whose path, after resolving symlinks, is or contains `$HOME`,
  `~/.claude`, `~/.claude.json`, the token file or the claudevm directory,
  lies inside `~/.claude` or the claudevm directory, contains a directory
  the guest system needs, such as `/etc`, `/tmp` or `/var`, or overlaps
  `/nix` or a guest path the VM uses (`/mnt/launch`, `/mnt/disk`,
  `/home/agent`).
- Claude config: Claude Code starts from the image's defaults, which mark
  onboarding as completed, the bypass permissions prompt as accepted and the
  workspace as trusted, select the dark theme, turn off syncing of the
  plugins enabled on your claude.ai account, turn off auto memory, which no
  later session would read, and turn off nonessential traffic and
  auto-updates. Nothing comes from the host's `~/.claude` or
  `~/.claude.json`. Project config comes from the workspace, where Claude
  Code reads `CLAUDE.md`, `.claude/` and `.mcp.json` as it does on the host
  in a trusted folder. The transcripts stay on the host in the session
  directory; prompt history and the rest of the VM's own Claude state are
  discarded with the VM.
- Token: the guest holds only the session's dummy key. Its Claude Code sends
  API requests to the broker on the host loopback, which QEMU's user-mode
  networking exposes at 10.0.2.2. The broker swaps the key for the token and
  passes the requests on; the token itself never enters the VM.
- Startup prompts: the session starts without the onboarding, the trust
  prompt, the bypass permissions prompt and the API key approval prompt. The
  guest tells Claude Code that it runs in a sandbox, which keeps the trust
  prompt away, and the image's defaults carry the answers, including the
  trust of the workspace and the approval of the session's key.
- Network: QEMU user-mode networking with DHCP and DNS, over IPv4 only;
  IPv6 is off. QEMU sends guest traffic out through the host's network
  stack, so the guest firewall rejects the destinations that are the host
  or its LAN: private, CGNAT, link-local, multicast and broadcast
  addresses, among them 10.0.2.2, through which QEMU reaches the host's
  loopback services. It makes three exceptions: the DHCP client's requests
  to QEMU at 10.0.2.2; DNS through 10.0.2.3, which QEMU forwards to the
  first nameserver in the host's `/etc/resolv.conf`, such as
  systemd-resolved on the host's loopback or a router on the LAN; and the
  broker's TCP port on 10.0.2.2, which the guest admits at boot. In the
  guest, systemd-resolved sends every lookup to 10.0.2.3 and to no other
  server, and runs no LLMNR or multicast DNS, so nothing in the guest
  listens for name queries from the network. The guest contacts no time
  server: its clock is kvm-clock, which takes the time from the host and
  keeps in step with it.
- Store: the guest's `/nix/store` shows the host's store read-only, with a
  writable overlay on the VM's disk for what the VM builds. The agent's own
  tools can reach every store path by its name but cannot list `/nix/store`
  or `/nix/store/.links`, and the share the overlay is built on is hidden.
  That share and the VM's launch directory at `/mnt/launch` are enforced
  read-only by virtiofsd on the host and mounted read-only in the guest.
- Disk: every launch creates an empty file in the disks directory,
  `~/claudevm/disks`, opens it, deletes its name, makes it a sparse file of
  `disk` MiB and starts QEMU on the open file as the VM's disk. The
  directory is therefore normally empty, and the host frees the file when
  QEMU exits, however the launch ends. A launch killed with SIGKILL, or a
  host crash, in the few system calls between creating the file and deleting
  its name leaves an empty `disk.*` file, which a later launch deletes once
  it is a minute old. The guest formats the disk ext4 at boot and keeps
  there what it writes to `/tmp`, `/var/tmp` and the agent's home, the
  store's writable overlay and Nix's build directories; all of it is
  discarded with the launch. The file grows with what the guest stores, plus
  the ext4 journal, about 260 MiB at the default size, and shows in `df` but
  not in `du`. Deleted files in the guest return their space to the host. A
  full disk gives ENOSPC to the writer, as a full file system does, and the
  session goes on; deleting files frees the space again. A full host file
  system ends the VM: the guest's file system stops at its next write after
  the one that failed, the guest kernel panics and QEMU exits with status 0;
  data that a program wrote without fsync just before is lost with the VM.
  `claudevm` refuses a disks directory that is a symlink, as it does a
  sessions directory.
- Open files: each virtiofsd of a launch, and QEMU, may hold as many open
  files as your hard limit (`ulimit -Hn`); a virtiofsd answers the guest
  with ENFILE before it runs out itself. It holds one for every file and
  directory of its share that the guest has cached and one more for every
  one the guest has open. Processes in the VM may hold about a quarter of
  that many files open; root's files count too, and only root may exceed
  it. Once the guest has cached more than half of it, it drops within a
  second the entries nothing uses; files kept open behind mappings,
  working directories and their parent directories stay, which in ordinary
  use are far fewer. A share that runs out before the drop answers opens,
  and lookups of paths the guest has not cached, with ENFILE, so exec and
  stat of such paths fail too until then.
- Memory: the session and the Nix daemon, with the builds it runs for the
  session, may together hold the guest's RAM less a fixed reserve of 256
  MiB, files they write to `/dev/shm` included; the guest has no swap. File
  data on the VM's disk counts only as cache, which the kernel writes back
  and reclaims at the limit, so `memory` is the memory of processes. The
  reserve holds the kernel's own memory, PID 1, the journal, which keeps at
  most 16 MiB, and the guest's other services, and is the same at every
  `memory`. The guest's RAM is what its kernel reports, somewhat less than
  `memory`: 3917 MiB at 4096. When the session and the daemon reach their
  limit, the kernel kills the one process among them that holds the most
  memory, and the session goes on as long as Claude Code or the debug shell
  itself runs.
- Nix: flakes are enabled; `nix develop` and `nix build` work inside.
- Hardening: the guest has no nested virtualization or KVM, no user
  namespaces, no io_uring and no setuid or file-capability programs, `sudo`
  included, and nothing the session runs can gain privileges. Only root can
  read the VM's disk as a block device, and setuid bits and device nodes
  on it have no effect. Only root can open `/dev/fuse` and the device nodes
  of the blacklisted vhost, vsock, VFIO and tun modules, which would stay
  out of the session's reach even with their module loaded. The guest's
  kernel loads no line discipline on demand and none of the blacklisted
  modules of unused devices, socket families and netlink protocols. Claude
  Code's own sandbox mode and other tools built on bubblewrap therefore do
  not work in the VM; `nix build` does. No process in the VM leaves a core
  dump: the kernel hands every dump to a program that discards it, so none
  fills the VM's disk or RAM or lands in a shared directory.
- Git: commits made in the VM carry your identity. At launch `claudevm`
  reads `user.name` and `user.email` as git on the host resolves them in
  the workspace, conditional includes of your global config included, and
  makes them the agent's global git config. A key the host does not set
  stays unset in the VM, where git then refuses to commit as it would on
  the host. Nothing else of your git config enters the VM: no aliases,
  signing keys or credential helpers. `claudevm` warns at launch if `.git`
  is a file (linked worktrees, submodules); git will not work inside the
  VM then. After the session it prints a NOTICE if `.git`, `.git/config`
  or `.git/hooks` changed.
- Configuration: after the session `claudevm` prints a NOTICE if
  `claudevm.toml` changed in any way since the launch read it: its content,
  its mode or the entry itself, for example replaced with a symlink or
  removed. The next launch reads it to decide which host directories the
  VM shares and which packages the host builds, so review the change
  before launching again; the NOTICE does not stop that launch. It covers
  `claudevm.toml` itself, not the content of a workspace flake that a
  relative `forward_packages` entry builds.

## What the sandbox does not protect

- The workspace is fully writable, including `.git`. The NOTICE reports git
  metadata changes; it does not prevent them. Writable mounts are as exposed
  as the workspace.
- Workspace content can steer tools you later run there on the host, such as
  git hooks and config or build scripts. Treat it after a session as you
  would a freshly cloned repository.
- A launch with `forward_packages` builds whatever the named flakes define,
  including a workspace flake the agent may have edited: the same trust as
  running `nix build` in that repository yourself.
- The agent can edit `claudevm.toml`, and the next launch shares the host
  directories and builds the packages the file then names. The NOTICE
  reports the change; it does not prevent it.
- The internet is open, so anything readable inside the VM can in principle
  be sent out, including any host store path the agent can name.
- A garbage collection, which any user in the VM can start, makes the Nix
  daemon walk the whole host store as root, with only the dropping of
  unused entries keeping the store share from running out, and delete
  through the overlay every path that the guest's database does not
  register or that no garbage collection root keeps. The `forward_packages`
  outputs and their closure are registered and rooted, so a collection
  keeps them; it hides every other host-only store path from the VM for
  the rest of the session, and `nix-store --gc --print-dead` reports their
  names.
- A host service listening on a public IPv4 address of the host is
  reachable: the guest firewall tells destinations apart by address range
  and cannot tell the host's public address from the rest of the internet.
- Everything that runs in the VM is one trust domain with one guest key: a
  dependency, a build script or an MCP server there can do whatever the
  agent can.
- Anything running in the VM can send API requests through the broker while
  the session lasts, and so use your account; it cannot read the token.
- The workspace, writable mounts and the session directory can grow until
  the host filesystem they live on is full, and the VM's disk image up to
  `disk` MiB, so a runaway process in the VM can fill the host disk.
- When the session runs out of memory, the process the kernel kills is the
  one that holds the most, which can be Claude Code itself, for example
  when files in `/dev/shm` rather than a process hold the memory; the
  session then ends.
- Shared directories are shared as they are, so a symlink inside one
  resolves inside the VM, not on the host: it reaches a host file only when
  that file lies in a shared directory too.

## Requirements

- x86_64 Linux host with Nix and flakes enabled.
- `/dev/kvm` writable by you. There is no software-emulation fallback.
- A hard limit of open files (`ulimit -Hn`) of at least 65536.
- The claudevm directory on a disk file system with room for the VM's
  disk: one in RAM, such as a tmpfs, would hold the disk's data in RAM.
- Unprivileged user namespaces for virtiofsd's sandbox (Ubuntu 24.04's
  AppArmor policy blocks them by default).
- A token stored with `claudevm login`. `claude setup-token`, which makes
  one, requires a Claude subscription.

## Tuning

VM size, extra mounts, plugin mounts and forwarded packages are set per
project in `claudevm.toml` and take effect at the next launch without rebuilding
`claudevm`. `claudevm.vcpu` and `claudevm.memory` in `nix/guest/machine.nix`
and `claudevm.disk` in `nix/guest/disk.nix` are the defaults that
`claudevm init` writes and that apply to a key the file leaves out.
`claudevm.claudeCode` is the Claude Code of the VM and of `claudevm login`,
by default the `claude-code` of the nixpkgs in `flake.lock`.

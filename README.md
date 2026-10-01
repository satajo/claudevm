# claudevm

Runs Claude Code with `--dangerously-skip-permissions` in an ephemeral QEMU
microVM (microvm.nix). The VM can write the current directory and the extra
directories `claudevm.toml` marks writable; it can read an allowlisted copy
of your Claude config, the host nix store and the read-only extra
directories; nothing else on the host filesystem is shared. When the session
ends the VM powers off and all its state outside those directories is gone.

## Usage

```
cd ~/projects/some-repo
nix run /path/to/claudevm -- init                          # write ./claudevm.toml
nix run /path/to/claudevm -- launch                        # start Claude Code
nix run /path/to/claudevm -- launch "summarize this repo"  # arguments go to claude
```

To install `claudevm`, use `nix profile install /path/to/claudevm`, or add
the flake as an input and its `packages.x86_64-linux.default` to your
packages. The commands are then `claudevm init`, `claudevm launch` and
`claudevm shell`.

Boot waits for the guest network and takes about ten seconds. When Claude
Code exits, the VM powers off and `claudevm` cleans up; a failed guest mount
also powers it off. SIGINT, SIGHUP or SIGTERM stops QEMU and virtiofsd.

- `claudevm shell` gives a debug shell instead of Claude Code.
- `claudevm` without a subcommand or with an unknown one prints usage.
- The terminal size is applied once at launch; resizes do not reach the
  serial console. Host environment variables other than `TERM` stay out.
- The exit status is QEMU's, not Claude Code's; 1 if a launch check fails or
  virtiofsd dies mid-session; 2 on a usage error; 129/130/143 on
  SIGHUP/SIGINT/SIGTERM.

## Configuration

`launch` and `shell` require a `claudevm.toml` in the working directory.
`claudevm init` writes one with the defaults and refuses to overwrite an
existing file. `claudevm` reads it once at launch, so edits made during a
session apply from the next launch. Every key is optional:

```toml
vcpu = 4          # default 4, clamped to 1..host CPUs
memory = 4096     # MiB, default 4096, clamped to 512..host MemTotal

[[mounts]]        # one table per extra host directory
path = "~/data"   # absolute, or starting with ~/
writable = false  # default false: read-only
```

- Unknown keys, wrong types and values that are not positive integers are
  errors, reported before anything starts. `graphics` and `resolution` are
  reserved and rejected as not implemented yet.
- A clamped value is shown as `(clamped from N)`. `memory = 2048` launches
  with 2047 MiB, because QEMU's microvm machine hangs at boot with exactly
  2 GiB.
- A mount appears in the guest at its host path with symlinks resolved.
  Read-only mounts are enforced by virtiofsd on the host. Files written to a
  writable mount are owned by you on the host.
- `claudevm` refuses a mount path that does not exist, is not a directory,
  is or contains `$HOME` (directories under it are fine), overlaps
  `~/.claude`, `~/.claude.json`, the workspace, `/nix`, a guest path the VM
  uses (`/workspace`, `/mnt/launch`, `/home/agent`) or another mount.
- `claudevm.toml` lives in the workspace, so it is visible and editable
  inside the VM by design. Every launch prints the effective configuration
  before the VM starts: the workspace, each mount with `ro` or `rw`, vcpu and
  memory.

## What the VM can and cannot do

```
Host                        Guest
----                        -----
$PWD            rw   --->   /workspace
[[mounts]] dirs ro   --->   same path            rw with writable = true
~/.claude       copy --->   ~agent/.claude       allowlisted entries; guest
                                                 writes are discarded
~/.claude.json  copy --->   ~agent/.claude.json  without its projects map
/nix/store      ro   --->   /nix/.ro-store       plus a writable overlay
host loopback   blocked
internet, LAN   outbound only, nothing inbound
everything else not shared
```

- Workspace: shared read-write over virtiofs, live in both directions. Files
  the agent creates are owned by you on the host. `claudevm` refuses a
  workspace whose path, after resolving symlinks, is or contains `$HOME`,
  `~/.claude` or `~/.claude.json`, or lies inside `~/.claude`.
- Claude config: each launch copies `settings.json`, `CLAUDE.md`,
  `keybindings.json`, `.credentials.json`, `agents`, `commands`, `skills`,
  `plugins`, `hooks` and `output-styles` into a read-only share, mounted
  under a tmpfs-backed overlay. Transcripts, prompt history, todos and other
  per-project data never enter the VM and the VM's own are discarded, so
  `claude --resume` does not work across runs. OAuth refreshes inside the VM
  are discarded too; after long sessions the host may need to log in again.
- Network: QEMU user-mode networking with DHCP and QEMU's DNS resolver. The
  guest firewall rejects 10.0.2.2 and fec0::2, through which QEMU would
  reach the host's loopback services.
- Nix: flakes are enabled; `nix develop` and `nix build` work inside.
- Git: `claudevm` warns at launch if `.git` is a file (linked worktrees,
  submodules); git will not work inside the VM then. After the session it
  prints a NOTICE if `.git`, `.git/config` or `.git/hooks` changed.

## What the sandbox does not protect

- The workspace is fully writable, including `.git`. The NOTICE reports git
  metadata changes; it does not prevent them. Writable mounts are as exposed
  as the workspace.
- Workspace content can steer tools you later run there on the host, such as
  git hooks and config or build scripts. Treat it after a session as you
  would a freshly cloned repository.
- Outbound network is open, so anything readable inside the VM, including
  the entire host nix store, can in principle be sent out. LAN hosts and
  host services listening on non-loopback addresses are reachable.
- The staged config includes `.credentials.json`, so your OAuth credential
  is inside the VM. A host-side token proxy that keeps it out is planned.
- Symlinks in the staged entries are dereferenced when copying, so whatever
  they point to on the host is copied into the VM.

## Requirements

- x86_64 Linux host with Nix and flakes enabled.
- `/dev/kvm` writable by you. There is no software-emulation fallback.
- Unprivileged user namespaces for virtiofsd's sandbox (Ubuntu 24.04's
  AppArmor policy blocks them by default).
- `~/.claude` with a completed login from running `claude` on the host.

## Tuning

VM size and extra mounts are set per project in `claudevm.toml` and take
effect at the next launch without a rebuild. `claudevm.vcpu` and
`claudevm.memory` in `nix/guest.nix` are the defaults that `claudevm init`
writes and that apply to a key the file leaves out. Claude Code comes from
the nixpkgs in `flake.lock`.

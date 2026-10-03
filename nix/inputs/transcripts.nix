# The session directory, a directory of its own for each launch under the
# sessions directory of the claudevm directory. The guest sees it
# read-write through a share, as the agent's ~/.claude/projects, where
# Claude Code writes the transcripts of the session.
#
# Uses from the launcher: workspace and claudevm_home. Uses from shares:
# add_share.
# Defines for add_share of shares and for the launcher's cleanup:
# session_dir, which the launcher sets empty and this sets before it calls
# add_share.
{ config, lib, pkgs }:

let
  agent = config.users.users.agent;
  findmnt = lib.getExe' pkgs.util-linux "findmnt";
  mount = lib.getExe' pkgs.util-linux "mount";
in
{
  # The session directory is named after the UTC time the launch starts
  # and the first 200 bytes of the workspace's name, with -2, -3 and so on
  # appended while the name is taken, which keeps it within the 255 bytes
  # of a directory name. claudevm_home has its symlinks resolved; a
  # sessions directory that is a symlink would put the session directories
  # outside it, where add_share does not keep them from the VM.
  collect = ''
    sessions_dir=$claudevm_home/sessions
    if [ -L "$sessions_dir" ]; then
      echo "claudevm: $sessions_dir is a symlink; the sessions directory must be a directory" >&2
      exit 1
    fi
    mkdir -p "$sessions_dir"
    chmod 0700 "$sessions_dir"
    # LC_ALL=C makes the substring count bytes, in the subshell only. The
    # trailing . keeps trailing newlines of the name, which the command
    # substitution would strip.
    workspace_prefix=$(LC_ALL=C; name=''${workspace##*/}; printf '%s.' "''${name:0:200}")
    session_name=$(date -u +%Y-%m-%dT%H-%M-%SZ)-''${workspace_prefix%.}
    session_path=$sessions_dir/$session_name
    session_number=1
    until mkdir_error=$(mkdir -m 0700 "$session_path" 2>&1); do
      if [ ! -e "$session_path" ] && [ ! -L "$session_path" ]; then
        echo "claudevm: $mkdir_error" >&2
        exit 1
      fi
      session_number=$((session_number + 1))
      session_path=$sessions_dir/$session_name-$session_number
    done
    session_dir=$session_path
    add_share "$session_dir" rw "$session_dir as session directory" "the session directory $session_dir"
  '';

  summary = ''
    printf 'claudevm: %-9s  rw  %s\n' session "$session_dir"
  '';

  # The entry holds the path of the session directory, at which the guest
  # mounts its share, as a NUL-terminated field.
  write = ''
    printf '%s\0' "$session_dir" > "$runtime/launch/transcripts"
  '';

  # Claude Code keeps its transcripts under ~/.claude/projects. Without
  # the share at the path of the entry, the bind mount would put them on
  # the guest's own file system, which vanishes with the VM.
  setup = ''
    if ! { IFS= read -r -d "" session_dir && ! IFS= read -r -d "" rest && [ -z "$rest" ]; } < /mnt/launch/transcripts \
        || [[ $session_dir != /* ]]; then
      echo "/mnt/launch/transcripts holds no absolute path" >&2
      exit 1
    fi
    if ! ${findmnt} --mountpoint "$session_dir" --types virtiofs --options rw > /dev/null; then
      echo "/mnt/launch/transcripts names $session_dir, at which no read-write share is mounted" >&2
      exit 1
    fi
    mkdir ${agent.home}/.claude/projects
    ${mount} --bind "$session_dir" ${agent.home}/.claude/projects
  '';

  session = "";
}

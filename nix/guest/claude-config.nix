{ config, lib, pkgs, ... }:

let
  agent = config.users.users.agent;

  # The Claude Code config of the image, which every session starts from
  # and nothing from the host adds to. Claude Code asks once per
  # installation to accept bypass permissions mode and records the answer
  # in settings.json; syncClaudeAiPlugins = false keeps the plugins enabled
  # on the claude.ai account out of the VM. Auto memory is off because no
  # later session reads what one session remembers: each launch gets a
  # session directory of its own as ~/.claude/projects, where Claude Code
  # keeps the memory of a project. The empty attribution texts keep Claude
  # Code's trailer out of commit messages and its note out of pull request
  # descriptions.
  claudeSettings = pkgs.writeText "claude-settings.json" (builtins.toJSON {
    skipDangerousModePermissionPrompt = true;
    syncClaudeAiPlugins = false;
    autoMemoryEnabled = false;
    attribution = {
      commit = "";
      pr = "";
    };
  });
  # The ~/.claude.json the image starts from. The setup of the shares input
  # adds the trust of the workspace and that of broker-access the approval
  # of the guest key.
  claudeState = pkgs.writeText "claude.json" (builtins.toJSON {
    hasCompletedOnboarding = true;
    theme = "dark";
    customApiKeyResponses.rejected = [ ];
  });
in
{
  options.claudevm.homeSteps = {
    claudeConfig = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      description = "Step of the claudevm-home script that installs the Claude Code config of the image for agent.";
    };
    claudeTmpDir = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      description = "Step of the claudevm-home script that creates the directory of Claude Code's temporary files for agent.";
    };
  };

  config.claudevm.homeSteps = {
    claudeConfig = ''
      install -d -o ${agent.name} -g ${agent.group} -m 0700 ${agent.home}/.claude
      install -o ${agent.name} -g ${agent.group} -m 0600 ${claudeSettings} ${agent.home}/.claude/settings.json
      install -o ${agent.name} -g ${agent.group} -m 0600 ${claudeState} ${agent.home}/.claude.json
    '';

    # Claude Code refuses to run when /tmp/claude-<uid>, the directory it
    # keeps its temporary files in, belongs to another user.
    claudeTmpDir = ''
      install -d -o ${agent.name} -g ${agent.group} -m 0700 /tmp/claude-${toString agent.uid}
    '';
  };
}

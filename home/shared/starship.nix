# Shared Bash prompt used by mixi and nixpad. This mirrors the workstation's
# prompt while keeping that host's existing configuration untouched.
{ lib, ... }:

{
  programs.bash.enable = true;

  # One line, dot separators; segments appear only when relevant. The SSH
  # hostname is shown only on remote sessions.
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;

      format = lib.concatStrings [
        "$username" "$hostname" "$directory"
        "$git_branch" "$git_status" "$git_state"
        "$nix_shell" "$cmd_duration" "$jobs" "$status" "$character"
      ];

      username = {
        show_always = true;
        format = "[$user]($style)";
        style_user = "bold cyan";
        style_root = "bold red";
      };

      hostname = {
        ssh_only = true;
        format = "[ · ](dimmed)[$hostname]($style)";
        style = "bold yellow";
      };

      directory = {
        format = "[ · ](dimmed)[$path]($style)[$read_only]($read_only_style)";
        style = "bold blue";
        truncation_length = 3;
        truncation_symbol = "…/";
        truncate_to_repo = false;
        read_only = " ";
        read_only_style = "yellow";
      };

      git_branch = {
        format = "[ · ](dimmed)[$branch]($style)";
        style = "bold magenta";
      };

      git_status = {
        format = "( [$all_status$ahead_behind]($style))";
        style = "yellow";
        conflicted = "[=\${count}](bold red)";
        untracked = "[?\${count}](blue)";
        modified = "[*\${count}](yellow)";
        staged = "[+\${count}](green)";
        renamed = "[»\${count}](yellow)";
        deleted = "[✘\${count}](red)";
        stashed = "[≡\${count}](dimmed)";
        ahead = "[↑\${count}](cyan)";
        behind = "[↓\${count}](cyan)";
        diverged = "[↑\${ahead_count}↓\${behind_count}](bold red)";
      };

      git_state = {
        format = "[ · ](dimmed)[\\($state $progress_current/$progress_total\\)]($style)";
        style = "bold yellow";
      };

      nix_shell = {
        format = "[ · ](dimmed)[$symbol$state]($style)";
        symbol = "❄ ";
        style = "bold blue";
        impure_msg = "impure";
        pure_msg = "pure";
        unknown_msg = "nix";
      };

      cmd_duration = {
        format = "[ · ](dimmed)[$duration]($style)";
        style = "yellow";
        min_time = 2000;
      };

      jobs = {
        format = "[ · ](dimmed)[$symbol$number]($style)";
        symbol = "✦";
        style = "bold blue";
        number_threshold = 1;
      };

      status = {
        disabled = false;
        format = "[ · ](dimmed)[$symbol$status]($style)";
        symbol = "✗";
        style = "bold red";
      };

      character = {
        format = "[ · ](dimmed)[$symbol]($style) ";
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };
    };
  };
}

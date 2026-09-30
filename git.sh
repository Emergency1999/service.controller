#!/bin/bash
# GIT COMMANDS
declare -A git_commands=(
  [commit]="<message>:Add and commit all changes with <message> and create a borg backup that is never pruned"
  [configure]=":Configure git user.name and user.email"
)

# DOCKER GLOBAL SUB-COMMANDS
add_global_subcommand "git" "commit"

# GIT SUB COMMAND
commands+=([git]=":Manage Git operations")
cmd_git() {
  local command="$1"

  # check if ":" is in the command
  if [[ $command == *":"* ]]; then
    # split the string by ":"
    IFS=":" read -ra command_parts <<<"$command"

    for command_part in "${command_parts[@]}"; do
      cmd_git $command_part
    done
    return 0
  fi

  if [[ ! " ${!git_commands[@]} " =~ " $command " ]]; then
    print_help "git " "git_commands"
    if ! [[ -z "$command" ]]; then
      echo
      echo "Unknown command: git $command"
    fi
    exit 1
  fi

  cd $SERVICE_DIR
  shift # remove first argument ("git" command)
  git_$command "$@"
}

# FUNCTIONS
git_commit() {
  local message="$1"
  if [[ -z "$message" ]]; then
    echo "Commit message is required"
    exit 1
  fi

  git add .
  git commit -m "$message"
  echo "Committed changes with message: $message"
  # a backup starting with "+" is never pruned; the service runs, so a file may change meanwhile
  BORG_WARNINGS_OK=1 borg_backup "+commit: $message"
}

git_configure() {
  read -p "Enter git user.name: " git_user_name
  read -p "Enter git user.email: " git_user_email

  if [[ -z "$git_user_name" || -z "$git_user_email" ]]; then
    echo "Both user.name and user.email are required"
    exit 1
  fi

  git config --global user.name "$git_user_name"
  git config --global user.email "$git_user_email"

  echo "Configured git with user.name='$git_user_name' and user.email='$git_user_email'"
}

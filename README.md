# Service Controller

This repository controls all services in different directories.

## Basic structure

| .env # all borg variables for borg, used for backing up and restoring services
| service.controller/
| | - controller.sh # add or remove any services
| | - core.sh # core functionality for other services
| | - init.sh # script to initialize a server
|
| service/
| | - service.sh # uses core from service.controller.

## Initialize

You can use this script to initialize the folder structure on the server.

```bash
curl -O https://raw.githubusercontent.com/Emergency1999/service.controller/refs/heads/main/init.sh && bash init.sh; rm init.sh
```

- services folder name  
  this is the folder where all services will be stored. Default is `services`.
- controller folder name  
  this is the folder (inside the services folder), where the controller scripts will be stored. Default is `controller`.

## Controller commands

Run in the services folder: `./controller.sh <command>`.

| Command | Description |
|---|---|
| `help` | Show the help message |
| `create <name> [template]` | Create a new service from a template (default: the template named like the service, else `default`) |
| `import <name...>` | Import one or more existing services from borg |
| `remove <name...>` | Remove one or more services (asks to stop and back up first) |
| `rename <old> <new>` | Rename a service (moves folder and borg repo) |
| `update` | Update the controller to the latest version |
| `version info [name...]` | Show the images with updates of the services given, or of all in `.backup` |
| `version upgrade [-y] [--ignore-health] [name...]` | Upgrade the images of the services given, or of all in `.backup`; asks per service unless `-y` |
| `borg change-passphrase <name> <old-passphrase>` | Change the passphrase of a repository to the current one |
| `borg autobackup-now` | Back up all enabled services now |
| `borg list-repos` | List all borg repos under `$BORG_REPO_BASE`, including orphaned ones |
| `borg delete-repo <name>` | Delete a borg repo (shows recent archives, requires confirmation) |

## Service commands

Run in a service folder: `./service.sh <command>`. Commands can be chained with `:`, e.g.
`./service.sh up:logs`. The commands marked *also top-level* can be called without their group,
e.g. `./service.sh up` for `./service.sh docker up`.

### docker

| Command | Description |
|---|---|
| `docker up` | Apply Docker Compose and start the service — *also top-level* |
| `docker down` | Stop and remove the service — *also top-level* |
| `docker start` / `stop` / `restart` | Start, stop or restart the existing containers — *also top-level* |
| `docker pull` / `build` | Pull or build the images — *also top-level* |
| `docker logs` / `status` | Show logs or status — *also top-level* |
| `docker exec <container> <command>` | Execute a command in a container — *also top-level* |
| `docker delete-volumes` | Delete the volumes — *also top-level* |

### borg

| Command | Description |
|---|---|
| `borg init` | Create the remote repository |
| `borg info` / `list` | Show repository information / list all backups |
| `borg backup <name>` | Back up the current data — *also top-level* |
| `borg restore-fresh <name> [--clean-git]` | Delete the data and restore it from a backup |
| `borg restore-diff <name> [--clean-git]` | Restore from a backup without deleting the current data first |
| `borg export <file> <name>` | Export a backup to a .tar file |
| `borg delete <name>` | Delete a backup |
| `borg prune` | Prune old backups (keeps backups whose name starts with `+`) — *also top-level* |
| `borg compact` | Compact the repository |
| `borg break-lock` | Break the repository lock — use with caution |
| `borg autobackup-enable` / `autobackup-disable` | Add or remove the service from the nightly backup list |
| `borg autobackup-now <logfile>` | Back up and prune now |

### git

| Command | Description |
|---|---|
| `git commit <message>` | Commit all changes and create a borg backup that is never pruned — *also top-level* |
| `git configure` | Configure git user.name and user.email |

### version

For services that pin their images by digest in a `.version` file.

| Command | Description |
|---|---|
| `version add <name> <repo> [target] [hash]` | Add an image to `.version` and put it into `docker-compose.yml` |
| `version info` | Show the current and the target hash of every image with their tags |
| `version search <name/repo> <hash/tag>` | Show all tags that belong to a hash or tag |
| `version running` | Show the image hash of every running container with its tags and dates |
| `version history [name]` | List the backups of replaced versions with their dates |
| `version upgrade [-y/names] [--ignore-health]` | Upgrade to the digests the targets point to (backup, up, health check, commit; restores on failure) |
| `version restore <backup> [-y/-n]` | Stop the service, restore the backup, start it again |

Templates can add their own commands (e.g. `occ` for nextcloud, `users` for ntfy); `./service.sh help`
lists them.

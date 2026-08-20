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

## Usage

```bash
./controller.sh help
```

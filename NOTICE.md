This project is MIT licensed.

Portions of the Azure restore-container approach were adapted from:

- `grrlgeek/bak-to-bacpac`
- Copyright (c) 2020 Jes Schultz
- License: MIT

The original repository provided the baseline idea of:

- staging a `.bak` into Azure storage
- restoring it in a temporary SQL Server container
- converting the restored database into a `.bacpac`

This repository changes that approach substantially for a modern cross-platform workflow:

- restore-only Azure container image
- external `SqlPackage` export/import using a current host installation
- modern `mssql-tools18`
- sanitization/export of unsupported objects before bacpac creation
- cross-platform PowerShell orchestration


# bak-to-bacpac-cli

`bak-to-bacpac-cli` converts a SQL Server `.bak` into a `.bacpac` and imports it into Azure SQL Database without requiring a Windows VM.

It is designed to make this workflow practical from macOS, including Apple Silicon Macs, where the old Windows-first restore and export path is especially painful.

This tool builds on the very helpful work from @grrlgeek and the original [`bak-to-bacpac`](https://github.com/grrlgeek/bak-to-bacpac) project.

The tool uses Azure for the restore step:

1. upload the `.bak` to Azure Files
2. start a temporary SQL Server in Azure Container Instances
3. restore the backup there
4. optionally remove objects Azure SQL will not import
5. export a `.bacpac` with local `SqlPackage`
6. import that `.bacpac` into Azure SQL Database
7. clean up temporary Azure resources

## Why use it

Use this when you have a SQL Server backup file and need to get it into Azure SQL Database, but you do not want to:

- build a Windows VM just to run restore/export tooling
- leave macOS or Apple Silicon just to get a `.bak` into Azure SQL Database
- do the restore and bacpac export manually
- guess which objects Azure SQL will reject during import

The tool preserves unsupported objects as `.sql` files before removing them from the temporary restored source, so you get:

- an importable Azure SQL database
- a report of what was excluded
- the SQL definitions for later review

## What it needs

On the machine running the CLI:

- PowerShell 7+
- Azure CLI
- `SqlPackage`
- a compatible .NET runtime for `SqlPackage`

Supported operator environment:

- macOS
- Apple Silicon and Intel Macs
- Linux, as long as the same prerequisites are installed

Azure access:

- permission to work with resource groups, storage, ACR, ACI, and the target Azure SQL server
- Azure CLI already logged in with the correct subscription selected

Optional:

- Docker, only if you want to build or test the restore container locally

If `SqlPackage` is installed but not runnable, the script first tries a user-local runtime at `~/.dotnet-sqlpackage` by setting `DOTNET_ROOT` before failing. If that runtime is also missing or incompatible, install the runtime requested by `sqlpackage /Version`.

This matters most on Apple Silicon, where `SqlPackage` may be present but still need a matching local .NET runtime before export and import will work.

## Quick start

Interactive wizard:

```bash
./bak-to-bacpac
```

Or:

```bash
pwsh ./scripts/bak-to-bacpac.ps1 -Mode full -Interactive
```

The wizard will prompt for:

- backup path
- target Azure SQL server and database
- SQL admin username and password
- Azure resource group and location
- temporary Azure resource names
- whether unsupported objects should only be reported or also dropped from the temporary restored source
- whether temporary resources should be kept for debugging

Before it runs, it prints a summary and asks for confirmation.

## Non-interactive use

Full migration:

```bash
pwsh ./scripts/bak-to-bacpac.ps1 \
  -Mode full \
  -BakPath /path/to/database.bak \
  -AzureSqlServerFqdn myserver.database.windows.net \
  -AzureSqlDatabaseName mydatabase \
  -SqlAdminUser myadmin \
  -SqlAdminPassword '<password>' \
  -AzureResourceGroupName my-rg \
  -ForceDropUnsupportedObjects
```

Show the planned workflow without doing anything:

```bash
pwsh ./scripts/bak-to-bacpac.ps1 -Mode plan
```

Show current saved state and what can be resumed:

```bash
pwsh ./scripts/bak-to-bacpac.ps1 -Mode status
```

## Modes

`plan`

- prints the intended workflow and sanitization behavior

`status`

- shows saved state, known inputs, artifacts on disk, and sensible next modes

`full`

- runs restore, sanitization, export, import, verification, and cleanup

`restore-only`

- creates or reuses Azure temp resources, uploads the `.bak`, restores it into temporary SQL Server, and saves resume state

`sanitize-only`

- reconnects to the temporary restored SQL Server, scans unsupported objects, writes reports, and optionally drops them from the temporary source

`export-only`

- exports a `.bacpac` from the temporary restored SQL Server

`import-only`

- imports an existing `.bacpac` into Azure SQL Database and verifies the result

`cleanup`

- deletes temporary Azure resources using the saved state

## Partial workflow

If you want to stop and inspect each stage, you can run:

1. `restore-only`
2. `status`
3. `sanitize-only`
4. `export-only`
5. `import-only`
6. `cleanup`

The tool stores resume information in `artifacts/state/last-run.json`.

## What gets written to `artifacts/`

- `artifacts/state/last-run.json`
- `artifacts/permission-report.json`
- `artifacts/sanitization-report.json`
- `artifacts/unsupported-objects/*.sql`
- exported `.bacpac` files

## Permission preflight

Before running Azure-backed stages, the tool checks effective Azure permissions for:

- storage account and file share operations
- Azure Container Registry operations
- Azure Container Instance operations
- Azure SQL server visibility

It writes the result to `artifacts/permission-report.json`.

## Sanitization behavior

Azure SQL Database will often reject objects that are valid in full SQL Server, especially:

- SQL users mapped to instance logins
- procedures, views, or functions with cross-database references
- server-level or instance-coupled objects

The tool handles that by:

1. scanning the temporary restored source
2. exporting unsupported definitions to `artifacts/unsupported-objects/`
3. writing `artifacts/sanitization-report.json`
4. dropping those objects only from the temporary restored source when allowed
5. exporting the `.bacpac`

It never modifies the original `.bak`.

## Safety and cleanup

- temporary Azure resources are deleted by default after a full successful run
- `cleanup` can be run later if you used keep mode or a run failed mid-way
- target Azure SQL database deletion is fallback-only and must be explicitly allowed

## Security notes

- do not put SQL passwords directly into shell history unless you accept that risk
- rotate temporary SQL admin passwords after use
- `artifacts/state/last-run.json` stores the temporary SQL `sa` password so partial modes can reconnect
- treat the state file as sensitive and delete it when you are done

## Cost notes

This workflow creates billable Azure resources while it runs, usually:

- Azure Container Registry
- Azure Files storage
- Azure Container Instances

Larger backup files increase runtime and storage cost.

## Files in this repo

- `bak-to-bacpac`: convenience launcher for macOS and Linux shells
- `scripts/bak-to-bacpac.ps1`: main entrypoint
- `scripts/helpers/`: Azure, SQL, sanitization, and common helpers
- `docker/`: restore container used in Azure
- `docs/compatibility.md`: notes on unsupported Azure SQL patterns

## License and attribution

This repository is MIT licensed. Attribution for the original MIT-licensed reference project is in [NOTICE.md](NOTICE.md).

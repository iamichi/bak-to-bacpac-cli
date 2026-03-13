# Compatibility Notes

## What Azure SQL Database rejects more often than people expect

- SQL users tied to instance logins
- cross-database references in procedures, views, and functions
- server-scoped or instance-scoped objects
- some platform-version metadata from newer SQL Server targets

## Recommended migration behavior

The tool should prefer a "make it importable, but preserve evidence" flow:

1. restore the `.bak` into a temporary SQL Server
2. detect unsupported objects
3. export those object definitions into `artifacts/unsupported-objects/`
4. generate a report such as `artifacts/sanitization-report.json`
5. drop unsupported objects from the temporary source only
6. export the bacpac
7. import into Azure SQL Database

## Example blocking patterns

Typical blockers seen during proving runs included:

- orphaned SQL users mapped to instance logins
- procedures, views, or functions with three-part names that reference another database
- maintenance routines that assume full SQL Server backup or cross-database behavior

Those are a good baseline test case for the sanitization feature.

for i in {1..60};
do
    /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT Name FROM SYS.DATABASES"
    if [ $? -eq 0 ]
    then
        echo "sql server ready"
        break
    else
        echo "not ready yet..."
        sleep 1
    fi
done

/opt/mssql-tools18/bin/sqlcmd -C -l 300 -S localhost -U sa -P "$SA_PASSWORD" -d master -i "/create_procedure_restoreheaderonly.sql"
/opt/mssql-tools18/bin/sqlcmd -C -l 300 -S localhost -U sa -P "$SA_PASSWORD" -d master -i "/create_procedure_restoredatabase.sql"

SQLPACKAGE_BIN="/opt/sqlpackage/sqlpackage"
if [ ! -x "$SQLPACKAGE_BIN" ]; then
    SQLPACKAGE_BIN="/sqlpackage/sqlpackage"
fi

for f in /mnt/external/*.bak;
do
    s=${f##*/}
    name="${s%.*}"
    extension="${s#*.}"
    echo "Restoring $f..."
    /opt/mssql-tools18/bin/sqlcmd -C -l 300 -S localhost -U sa -P "$SA_PASSWORD" -d master -q "EXEC dbo.restoredatabase '/mnt/external/$name.$extension', '$name'"
    if [ $? -ne 0 ]; then
        echo "Restore failed for $f"
        exit 1
    fi

    if [ "$SKIP_INTERNAL_EXPORT" = "1" ]; then
        echo "Skipping internal export for $name. Waiting for external export."
        tail -f /dev/null
    fi

    echo "Creating bacpac..."
    if [ ! -x "$SQLPACKAGE_BIN" ]; then
        echo "SqlPackage was not found in the container image."
        exit 1
    fi

    "$SQLPACKAGE_BIN" -a:"Export" -ssn:"localhost" -su:"sa" -sp:"$SA_PASSWORD" -sdn:"$name" -tf:"/mnt/external/$name.bacpac"
done

FROM mcr.microsoft.com/mssql/server

USER root

RUN apt-get -y update
RUN apt-get install -y curl gnupg unzip
RUN apt-get -y update
RUN ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev

COPY . /

RUN chmod 777 *.sql
RUN chown -R mssql:root *.sql
RUN chmod a+x ./restore-and-wait.sh
RUN mkdir /mnt/external
RUN chown -R mssql:root /mnt

USER mssql
ENTRYPOINT ["/bin/bash", "./entrypoint.sh"]


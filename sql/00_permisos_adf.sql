-- Ejecutar en sqldb-cripto con una cuenta de Microsoft Entra (no con sqladmin).
-- Bicep no puede crear usuarios dentro de la base de datos, por eso va aparte.
-- En prod, reemplaza el nombre por adf-cripto-prod-rffc.

CREATE USER [adf-cripto-dev-rffc] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [adf-cripto-dev-rffc];
ALTER ROLE db_datawriter ADD MEMBER [adf-cripto-dev-rffc];
GRANT EXECUTE TO [adf-cripto-dev-rffc];

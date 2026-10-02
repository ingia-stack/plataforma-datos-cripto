using 'main.bicep'

param env = 'prod'
param suffix = 'rffc'
param location = 'eastus2'
param sqlLocation = 'centralus'
param entraAdminLogin = 'rffrancoc@outlook.es'
param entraAdminObjectId = '159d71a3-7fc6-4ab2-9c65-003f62b5c1af'
param useSqlFreeOffer = true

param sqlAdminPassword = readEnvironmentVariable('SQL_ADMIN_PASSWORD')

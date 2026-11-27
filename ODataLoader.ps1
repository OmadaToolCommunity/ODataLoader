###################################################################################
# ODataLoader
#
# Copyright (c) 2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
# Usage:
# Perform CUD operations on Omada data objects from data in a csv file or database
# Enable OData access for the DOT to allow operations
#
###################################################################################

using module .\omadahttp.psm1
using module .\omadautility.psm1

param (
    [Parameter(Mandatory)]$configfile = '',
    $logpath = '.\logs',
    $connections = $null,
    $httpConfig = $null
)

Import-Module -Name $PSScriptRoot\lib\ODataLoader-ObjectBuilder.psm1 -Force
Import-Module -Name $PSScriptRoot\lib\ODataLoader-JobManager.psm1 -Force
Import-Module -Name $PSScriptRoot\lib\ODataLoader-Operations.psm1 -Force
Import-Module -Name $PSScriptRoot\lib\ODataLoader-Logging.psm1 -Force

$version = '2.8.0'

enum operation {
    FastCreate
    CreateIfNotExists
    CreateUpdate
    Update
    FastUpdateByOmadaId
    Delete
    FastDeleteByOmadaId
    UnDelete
    Test
    OPSReleaseJobs
    OPSArchiveJobs
    OPSRetryJobs
    ROPEQueueIdentites
    SetSystemReviewMode
    OPSExpireClaim
    SaveDataToCSV
    CreateAccessRequest
}

function ProcessObject1 {
    param (
        $config
        , $object
    )

    $oper = [operation]::($config.operation)

    switch ($oper) {
        ([operation]::Delete) { DeleteOmadaObject -config $config -object $object }
        ([operation]::CreateUpdate) { CreateUpdateOmadaObject -config $config -object $object }
        ([operation]::CreateIfNotExists) { CreateIfNotExistsOmadaObject -config $config -object $object }
        ([operation]::Update) { UpdateOmadaObject -config $config -object $object }
        ([operation]::Test) { TestOmadaObject -config $config -object $object }
        ([operation]::UnDelete) { UnDeleteOmadaObject -config $config -object $object }

        ([operation]::FastCreate) { ProcessFastOperationByOmadaId -config $config -operation Create -object $object }
        ([operation]::FastUpdateByOmadaId) { ProcessFastOperationByOmadaId -config $config -operation Update -object $object }
        ([operation]::FastDeleteByOmadaId) { ProcessFastOperationByOmadaId -config $config -operation Delete -object $object }

        ([operation]::OPSReleaseJobs) { OPSReleaseJobs -config $config -object $object }
        ([operation]::OPSArchiveJobs) { OPSArchiveJobs -config $config -object $object }
        ([operation]::OPSRetryJobs) { OPSRetryJobs -config $config -object $object }

        ([operation]::ROPEQueueIdentites) { ROPEQueueIdentites -config $config -object $object }
        ([operation]::SetSystemReviewMode) { OPSSetSystemPreviewMode -config $config -object $object }
        ([operation]::OPSExpireClaim) { OPSExpireClaim -config $config -object $object }

        ([operation]::CreateAccessRequest) { CreateAccessRequest -config $config -object $object }        
    }
}

function ProcessObject {
    param (
        $config
        , $object
    )

    $i = 1
    $oper = [operation]::($config.operation)
    $excep = $null
    do {
        $excep = $null
        try {
            ProcessObject1 -config $config -object $object
        }
        catch {
            $excep = $_
            AddLog -msg ('Error during object processing: ' + $excep.ToString()) -color Red
            AddLog ('Stack trace: ' + $excep.ScriptStackTrace) -color Red
        }
        $doRetry = $oper -in @([operation]::CreateUpdate) -and $i -lt 2 -and $null -ne $excep
        $i++
    } while ($doRetry)
}

function FinalizeProcessing {
    param (
        $config
    )

    $oper = [operation]::($config.operation)

    switch ($oper) {
        ([operation]::FastCreate) { ProcessFastOperationByOmadaId -config $config -operation Create -object $null -finalize $true }
        ([operation]::FastUpdateByOmadaId) { ProcessFastOperationByOmadaId -config $config -operation Update -object $null -finalize $true }
        ([operation]::FastDeleteByOmadaId) { ProcessFastOperationByOmadaId -config $config -operation Delete -object $null -finalize $true }

    }
    WaitForJobCompletion -config $config
    SaveObjectImportStatusList -config $config
}

function ApplyScriptFilter {
    param (
        $filter,
        $record
    )

    $sb = [ScriptBlock]::Create($filter.script)
    $res = Invoke-Command -ScriptBlock $sb -ArgumentList @($record)
    if ($res) {
        AddLog('Record filter: ' + $filter.name + ', skipping record: ' + ($record.($filter.recordProperty))) -color DarkYellow   
    }
    return $res
}

$global:excludeList = @{}
function ApplyCSVFilter {
    param (
        $filter,
        $record
    )

    if ($null -ne $filter.excludelistFile -and $global:excludeList.Keys -notcontains ($filter.excludelistFile)) {
        $global:excludeList[$filter.excludelistFile] = @(Import-Csv -Path ($filter.excludelistFile) -Delimiter ($filter.delimiter))
    }

    if ($null -ne ($filter.fileIdentifierCol) `
            -and $null -ne ($filter.recordProperty)) {
        $q = $global:excludeList.($filter.excludelistFile).($filter.fileIdentifierCol)
        $w = $record.($filter.recordProperty)
        if ($filter.ignoreCase -and $null -ne $w) {
            $q = $q.Foreach({ if ($null -ne $_ ) { $_.ToLower() } }) #TODO optimize by lower casing on file load
            $w = $w.ToLower()
        }
        if ($q -contains $w) {
            AddLog('Record filter: ' + $filter.name + ', skipping record with value "' + ($record.($filter.recordProperty)) + '"') -color DarkYellow
            return $true
        }
    }
    return $false
}
function ApplyFilters {
    param (
        $filterCfg,
        $record
    )

    foreach ($filter in $config.recordFilter) {
        if ($filter.filterType -eq 'Script') {
            $res = ApplyScriptFilter -filter $filter -record $record
        }
        elseif ($filter.filterType -eq 'CSVFile') {
            $res = ApplyCSVFilter -filter $filter -record $record
        }
        else {
            Throw 'Unknown filter type in record filters'
        }
        if ($res) {
            return $true;
        }
    }
    return $false
}
function ProcessRecords {
    param (
        $config,
        $list
    )

    $recNumber = 0
    if ($null -ne $config.startIndex -and $config.startIndex -gt 0) {
        $recNumber = $config.startIndex - 1
    }

    $objNumber = 0
    $endprocessing = $false
    while ($recNumber -lt $list.Count -and -not $endprocessing) {
        $rec = $list[$recNumber]

        if (($config.maxObjects) -gt 0 -and $objNumber -ge ($config.maxObjects)) {
            AddLog ('Processing stopped due to maxObjects processed (' + ($config.maxObjects) + ')')
            return $objNumber
        }

        $objNumber++

        $filtered = ApplyFilters -filterCfg $config.recordFilter -record $rec
        if ($filtered) {
            $recNumber++
            continue
        }

        AddLog ('"' + $config.ID + '" Processing object ' + $objNumber + ' from record ' + ($recNumber + 1) + ' of ' + $list.Count) -color Cyan
        $identifier = GetObjectIdentifier -config $config -record $rec

        if ($null -eq $identifier -or '' -eq ('' + $identifier).Trim()) {
            AddLog ('Skipping record ' + ($recNumber + 1) + ', identifier is empty - ' + ($rec.($config.sourceDisplayName))) -color DarkYellow
            $recNumber++
            continue
        }

        AddLog ('Object identifier: ' + $identifier + ' - "' + $rec.($config.sourceDisplayName) + '"')

        if ($config.progressTracking -and (GetObjectImportStatus -identifier $identifier) -eq 'C') {
            AddLog "Skipping object $objNumber, already processed" -color DarkYellow
            $recNumber++
            continue
        }

        $data = @{
            identifier = $null
            data       = @{}
            sourceData = $rec
        }
        $null = BuildObject -config $config -record $rec -res $data

        if ($null -eq $data.identifier) {
            AddLog ('Skipping record ' + ($recNumber + 1) + ', an error ocurred (see previous message)') -color Red
            $recNumber++
            continue
        }

        if ($recNumber -lt $list.Count - 1) {
            $combineIdx = 0
            do {
                $recNext = $list[$recNumber + 1]
                $filtered = ApplyFilters -filterCfg $config.recordFilter -record $recNext
                if ($filtered) {
                    $recNumber++
                    AddLog ('Record ' + ($recNumber + 1) + ' filtered out')
                    continue
                }

                $nextIdentifier = GetObjectIdentifier -config $config -record $recNext
                if ($data.identifier -eq $nextIdentifier) {
                    $recNumber++
                    $combineIdx++
                    AddLog ('Combining with record ' + ($recNumber + 1) + ' - "' + $recNext.($config.sourceDisplayName) + "`" - combineIdx $combineIdx")

                    $dataNext = @{
                        identifier = $null
                        data       = @{}
                        sourceData = $recNext
                    }
                    $null = BuildObject -config $config -record $recNext -res $dataNext

                    if ($null -eq $dataNext.identifier) {
                        AddLog('Combine skipped, no object was built')
                    }
                    else {
                        $data = CombineObjects -config $config -obj1 $data -obj2 $dataNext
                    }
                }

            } while (($recNumber -lt $list.Count - 1) -and ($data.identifier -eq $nextIdentifier))
        }

        if ($null -eq $data) {
            HandleProcessingError -config $config -msg ("Skipping record " + ($recNumber + 1) + ", no data")
        }
        else {
            ProcessObject -config $config -object $data

            if ($null -ne $config.sleep) {
                Start-Sleep -Milliseconds $config.sleep
            }
        }
        $recNumber++
    }
    return $objNumber
}

function GetMultilineConfigValue {
    param($config,
        $propName,
        $separator = $null)

    $res = $config.$propName
    $i = 2
    while ($null -ne $config.($propName + '.' + $i)) {
        $res += $separator
        $res += $config.($propName + '.' + $i)
        $i++
    }
    return $res
}

function ProcessDataimport {
    param (
        [Parameter(Mandatory)]$config
    )

    $oper = [operation]::($config.operation)

    if ($null -eq $oper) {
        AddLog -msg "Import skipped, illegal operation specified, use one of the following:" -color Red
        Write-Host ([operation].GetEnumValues())
        return
    }

    InitializeObjectImportStatusList -config $config

    $page = 0
    $lastIdentifier = $null

    #read sql query from file and insert into config object
    if ($null -ne $config.sourceSQLQueryFile) {
        $q = Get-Content -Path $config.sourceSQLQueryFile
        $q = $q -join "`n"
        Add-Member -InputObject $config -Name 'sourceSQLQuery' -Value $q -MemberType NoteProperty
    }
    if ($null -ne $config.sourceSQLQueryNextPageScriptFile) {
        $q = Get-Content -Path $config.sourceSQLQueryNextPageScriptFile
        $q = $q -join "`n"
        Add-Member -InputObject $config -Name 'sourceSQLQueryNextPageScript' -Value $q -MemberType NoteProperty
    }    

    do {
        $importSource = ''
        if ($null -ne $config.sourcefile -and $config.sourcefile -ne '') {
            $importSource = 'file'
            AddLog ('Reading data from csv file ' + $config.sourcefile)
            $list = @(Import-Csv -Path $config.sourcefile -Delimiter $config.sourceDelimiter)
        }
        elseif ($null -ne $config.sourceOmadaQueryDatabase -and $null -ne $config.sourceSQLQuery ) {
            $importSource = 'omadadb'
            
            $sourceSQLQuery = GetMultilineConfigValue -config $config -propName 'sourceSQLQuery' -separator ' '
            if ($page -eq 0) {
                AddLog ('Reading data from Omada database')
                if ($config.operation -eq [operation]::Test) {
                    AddLog ('Query: ' + $config.sourceSQLQuery)
                }
                $list = @(QueryOmadaDatabase -omadaHttp ($global:omadaHttp) -db $config.sourceOmadaQueryDatabase -query $sourceSQLQuery)
            }

            if ($page -gt 0 -and $null -ne $config.sourceSQLQueryNextPageScript) {
                AddLog ('Reading data from Omada database, page ' + ($page + 1) + ', last identifier: ' + $lastIdentifier)
                $sourceSQLQueryNextPageScript = GetMultilineConfigValue -config $config -propName 'sourceSQLQueryNextPageScript' -separator ' '
                $sb = [ScriptBlock]::Create($sourceSQLQueryNextPageScript)
                $sourceSQLQuery = Invoke-Command -ScriptBlock $sb -ArgumentList @($page, $lastIdentifier)
                if ($config.operation -eq [operation]::Test) {
                    AddLog ('Query: ' + $sourceSQLQuery)
                }
                $list = @(QueryOmadaDatabase -omadaHttp ($global:omadaHttp) -db $config.sourceOmadaQueryDatabase -query $sourceSQLQuery)
            }
            $lastIdentifier = $list[$list.Count - 1].($config.sourceLastIdentifierColumn)
            if ($list.Count -gt 0 -and $null -ne $config.sourceLastIdentifierColumn -and $null -eq $lastIdentifier) {
                Throw 'Last identifier value not resolved for pagination'
            }
        }
        elseif ($null -ne $config.sourceSQLServerDatabase) {
            $importSource = 'sqldb'
            AddLog ('Reading data from SQL database')
            $list = @(Invoke-Sqlcmd -ServerInstance $config.sourceSQLServerInstance -Database $config.sourceSQLServerDatabase -Query $config.sourceSQLQuery)
        }
        elseif ($null -ne $config.sourceConst) {
            $importSource = 'Const'
            AddLog ('Reading data from constant')
            $list = $config.sourceConst
        }
        elseif ($null -ne $config.sourceOmadaOdataObject) {
            $importSource = 'OData'
            if ($page -eq 0) {
                AddLog ('Reading data from Omada OData')
            }
            else {
                AddLog ('Reading data from Omada OData, page ' + $page)
            }

            if ($null -ne $config.sourceOmadaOdataParams) {
                $sourceOmadaOdataParams = $config.sourceOmadaOdataParams
            }
            elseif ($null -ne $config.sourceOmadaOdataParamsScript) {
                $sb = [ScriptBlock]::Create($config.sourceOmadaOdataParamsScript)
                $sourceOmadaOdataParams = Invoke-Command -ScriptBlock $sb -ArgumentList @($page)
            }

            $list = $global:omadaHttp.ODataGET($config.sourceOmadaOdataObject, $sourceOmadaOdataParams)
            $list = $list.value
        }
        elseif ($null -ne $config.sourceOPS) {
            $importSource = 'OPS'
            AddLog ('Reading data from Omada Provisioning Service')

            [int]$time = [Math]::Round((Get-Date).ToFileTime() / 10000000 - 11644473600)

            $batchsize = 100
            if ($null -ne $config.sourceOPS.batchsize) { $batchsize = $config.sourceOPS.batchsize }

            enum OPSJobStatus {
                Completed = 1
                Retry = 2
                Failed = 3
                Review = 5
                Partially_completed = 6
                Relayed = 7
            }

            [OPSJobStatus]$OPSJobStatus = $config.sourceOPS.OPSJobStatus

            $body = '{"_search":true,"nd":' + $time + ',"rows":' + $batchsize + ',"page":1,"sidx":"jobCreatedTime","sord":"desc",' `
                + '"filters":"{\"groupOp\":\"AND\",\"rules\":['`
                + '{\"field\":\"jobStatus\",\"op\":\"eq\",\"data\":\"' + ($OPSJobStatus.value__) + '\"}' `
                + ',{\"field\":\"jobTargetSystem\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPS.targetsystem + '\"}' `
                + ',{\"field\":\"jobOrigin\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPS.jobOrigin + '\"}' `
                + ',{\"field\":\"jobOriginId_Identity\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPS.identityName + '\"}' `
                + ']}",'`
                + '"dataType":"OPSInternalJobs","dataTypeArgs":{"originKeys":"Identity","targetSystemUId":"","maxMins":0},'`
                + '"searchField":null,"searchString":null,"searchOper":null}'

            $path = '/WebService/JQGridPopulationWebService.asmx/GetPagingData'
            $resp = ''
            $resp = $global:omadaHttp.InvokeOmadaRestMethod('Post', $path, $body)
            $list = $resp.d.Rows
            foreach ($l in $list) {
                Add-Member -InputObject $l -MemberType NoteProperty -Name 'batch' -Value 'Batch'
            }
        }
        elseif ($null -ne $config.sourceOPSClaims) {
            $importSource = 'OPSCLAIMS'
            AddLog ('Reading data from Omada Provisioning Claims')
                        
            $batchsize = 100
            if ($null -ne $config.sourceOPSClaims.batchsize) { $batchsize = $config.sourceOPSClaims.batchsize }
            enum OPSClaimStatus {
                Queued = 0
                Relayed = 1
                Failed = 2
                Completed = 3
            }
            [OPSClaimStatus]$OPSClaimStatus = $config.sourceOPSClaims.OPSClaimStatus
            
            [int]$time = [Math]::Round((Get-Date).ToFileTime() / 10000000 - 11644473600)
            $body = '{"_search":true,"nd":' + $time + ',"rows":' + $batchsize + ',"page":1,"sidx":"attemptedOn","sord":"desc",' `
                + '"filters":"{\"groupOp\":\"AND\",\"rules\":['`
                + '{\"field\":\"status\",\"op\":\"eq\",\"data\":\"' + ($OPSClaimStatus.value__) + '\"}' `
                + ',{\"field\":\"identityDisplayName\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPSClaims.identityName + '\"}' `
                + ',{\"field\":\"accountName\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPSClaims.accountName + '\"}' `
                + ',{\"field\":\"system\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPSClaims.targetsystemName + '\"}' `
                + ',{\"field\":\"resource\",\"op\":\"cn\",\"data\":\"' + $config.sourceOPSClaims.resource + '\"}' `
                + ']}",'`
                + '"dataType":"ProvisioningClaim","dataTypeArgs":{},'`
                + '"searchField":null,"searchString":null,"searchOper":null}'

            $path = '/WebService/JQGridPopulationWebService.asmx/GetPagingData'
            $resp = ''
            $resp = $global:omadaHttp.InvokeOmadaRestMethod('Post', $path, $body)
            $list = $resp.d.Rows
        }
        else {
            AddLog -msg 'No data source defined'
            return
        }
        AddLog ('Read resulted in ' + $list.Count + ' data records')

        if ($config.operation -eq 'SaveDataToCSV') {
            if ($page -eq 0 -and (Test-Path $config.object)) {
                Remove-Item $config.object -Force
            }
            $delim = ';'
            if ($null -ne $config.sourceDelimiter) {
                $delim = $config.sourceDelimiter
            }
            foreach ($itm in $list) {
                Export-Csv -Path $config.object -InputObject $itm -Encoding ansi -Append -Delimiter $delim
            }
        }
        else {
            $null = ProcessRecords -config $config -list $list -connections $connections    
            FinalizeProcessing -config $config
        }

        $page++

    } while ($importSource -in @('omadadb', 'sqldb', 'OData', 'OPS') `
            -and $null -ne $config.sourceMaxPages `
            -and $config.sourceMaxPages -gt $page `
            -and $list.Count -gt 0)
}

function ApplyConnectionSettingsToConfig {
    param (
        $config
        , $connections
    )

    foreach ($sc in $connections) {
        if ($sc.connectionName -eq $config.connectionName) {
            $keys = $($sc | Get-Member -MemberType *Property).Name
            foreach ($sckey in $keys) {
                if ($sckey.ToLower() -ne 'connectionName') {
                    $value = $sc.$sckey
                    Add-Member -InputObject $config -Name $sckey -Value $value -MemberType NoteProperty -Force
                }
            }
        }
    }
}

function InvokeMain {
    $local:config = ''
    $local:config = Get-Content -Raw $configfile -ErrorAction SilentlyContinue | ConvertFrom-Json

    if ($null -eq $local:config) {
        AddLog "Config file $configfile is empty or not found"
        return
    }

    InitLog -logPath $logPath -maxLogfiles $local:config.maxLogFiles

    if ($null -eq $script:httpConfig) {
        $hcfg = $config.httpConfig
    }
    else {
        $hcfg = $script:httpConfig
    }

    if ($null -eq $hcfg) {
        Throw 'No http configuration provided'
    }
    else {
        if ($null -eq $global:omadaHttp) {
            $global:omadaHttp = [OmadaHttp]::new($hcfg)
        }
        else {
            #reinitialize http config if changed
            $n = $global:OmadaHttp.GetOmadaHttpConfig().httpConfig
            if ($hcfg.authentication -ne $n.authentication `
                    -or $hcfg.webhost -ne $n.webhost `
                    -or ($hcfg.authentication.ToLower() -eq 'cookie' -and $hcfg.Cookie.Cookie -ne $n.Cookie.Cookie)) {
                $global:omadaHttp = [OmadaHttp]::new($hcfg)
            }
        }
    }

    AddLog ('============================================')
    AddLog ("Initializing ODataLoader version $version")

    try {
        $global:DOTSchema = Get-DOTSchema -config $global:omadaHttp
    }
    catch {
        $global:omadaHttp = $null
        AddLog -msg ("Error when reading DOT schema, terminating`r`n`r`n" + $_) -color Red
        exit
    }

    if ($global:DOTSchema.Count -eq 0) {
        AddLog -msg 'No DOT information found, terminating' -color Red
        exit
    }

    AddLog ('============================================')
    AddLog ('Processing starting')

    if ($null -eq $connections) {
        #if not as param from command line then get value from config file
        $connections = $config.connections
    }

    foreach ($c in $local:config.actions) {
        AddLog ('============================================')

        if ($c.Enabled) {
            AddLog ('Starting action "' + $c.ID + '" (' + $c.operation + ')' )
            try {
                $processingStart = Get-Date
                $null = ApplyConnectionSettingsToConfig -config $c -connections $connections
                ProcessDataimport -config $c
                $processingEnd = Get-Date
                AddLog ('Completed action "' + $c.ID + '" , processing time: ' + ($processingEnd - $processingStart))
            }
            catch {
                $ex = $_
                AddLog ('Action "' + $c.ID + '" stopped due to error: ' + $ex) -color Red
                AddLog ('Stack trace: ' + $ex.ScriptStackTrace) -color Red
            }
        }
        else {
            AddLog ('Skipping disabled action "' + $c.ID + '"')
        }
    }

    AddLog ('============================================')
    AddLog ('Processing completed')
    AddLog ('============================================')
}

if ($psversionTable.PSVersion.Major -lt 7) {
    Write-Host 'Please run this with Powershell version 7 or later'
    return
}

$null = InvokeMain

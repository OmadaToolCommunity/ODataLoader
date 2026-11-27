###################################################################################
# Omada ODataLoader - Loader operations
#
# Copyright (c) 2022,2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

Import-Module -Name $PSScriptRoot\ODataLoader-Logging.psm1 -Force
enum ODataOperation {
    Create
    Update
    Delete
}

function HandleProcessingError {
    param (
        [Parameter(Mandatory)]
        $config,
        [Parameter(Mandatory)]
        $msg
    )
    
    if ($config.onError -eq 'continue') {
        AddLog -msg $msg -color ([System.ConsoleColor]::Red)
    } 
    else {
        throw $msg
    }
}  

function GetOmadaObject {
    param (
        $config
        , $object
        , $selector = $null
    )

    if ($null -eq $config.targetObjectQuery -or '' -eq $config.targetObjectQuery) {        
        $n = $global:DOTSchema.($config.object).($config.targetIdentifier)
        
        $identifierEnc = $global:omadahttp.UrlEncode($object.identifier)
        
        if ($n -in @('Edm.Int32', 'Edm.Boolean', 'Edm.Guid')) {
            $params = '?$filter=' + $config.targetIdentifier + " eq " + $identifierEnc
        }
        else {
            $params = '?$filter=' + $config.targetIdentifier + " eq '" + $identifierEnc + "'" 
        }
    }
    else {
        $params = '?$filter='
        
        $tokens = $config.targetObjectQuery -split '{'
        foreach ($token in $tokens) {
            $t = $token -split '}'
            if ($t.Count -eq 2) {
                $params += $object.sourceData.($t[0]) + $t[1]
            }
            else {
                $params += $token
            }
        }
    }
    if ($null -ne $selector) {
        $params += '&$select=' + $selector
    }

    $res = $global:omadahttp.ODataGET(($config.object), $params)

    if ($res.value.Count -eq 0) {
        AddLog -msg ('Object not found, ' + $params)
        return $null
    }
    elseif ($res.value.Count -eq 1) {
        return $res.value
    }
    else {
        throw ('Error: More than one Data Object resolved by query: ' + $params)        
    }    
}

function GetOmadaObjectId {
    param (
        $config
        , $object
    )
    $res = GetOmadaObject -config $config -object $object -selector 'Id'
    return $res.Id
}
function DeleteOmadaObject {
    param (
        $config
        , $object
    )
        
    try {
        $id = GetOmadaObjectId -config $config -object $object
        if ($null -eq $id) {
            AddLog -msg ('Skipping delete, object not found for ' + $config.targetIdentifier + '=' + $object.identifier)
        }
        else {
            AddLog -msg ('Deleting object')
            $null = $global:omadahttp.ODataDELETE(($config.object), $id)
        }
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'C'        
    }
    catch {
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'E'
        HandleProcessingError -config $config -msg ('Error during deletion: ' + $_)
        HandleProcessingError -config $config -msg ('Stack trace: ' + $_.ScriptStackTrace)
    }
}

function UnDeleteOmadaObject {
    param (
        $config
        , $object
    )

    try {
        if ($null -eq $object.data.id) {
        }
        else {
            $body = '{"id":"' + $object.data.id + '"}'
            $null = $global:omadahttp.InvokeOmadaRestMethod('POST', '/WebService/DataObjectWebService.asmx/UndeleteDataObject', $body)
        }
    }
    catch {
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'E'
        HandleProcessingError -config $config -msg ('Error during deletion: ' + $_)
        HandleProcessingError -config $config -msg ('Stack trace: ' + $_.ScriptStackTrace)
    }
}

function ProcessFastOperationByOmadaId {
    param (
        $config
        , $object
        , [ODataOperation]$operation
        , $finalize = $false
    )

    $httpmethod = ''
    switch ($operation) {
        ([ODataOperation]::Create) { $httpmethod = 'POST' }
        ([ODataOperation]::Update) { $httpmethod = 'PUT' }
        ([ODataOperation]::Delete) { $httpmethod = 'DELETE' }
    }

    if ($null -ne $object) {
        AddLog -msg ('Adding ' + $operation + ' operation to batch')
        $null = $global:FastExecuteObjectList.Add($object)
    }
    
    if ($global:FastExecuteObjectList.Count -ge $config.batchSize `
            -or ($global:FastExecuteObjectList.Count -gt 0 -and $finalize)) {
        AddLog -msg ('Executing batch operation on ' + $global:FastExecuteObjectList.Count + ' objects')
        FastExecuteOmadaObject -config $config -httpmethod $httpmethod -objects $global:FastExecuteObjectList
        $global:FastExecuteObjectList = [System.Collections.ArrayList]@()
    } 
}

function UpdateOmadaObject {
    param (
        $config
        , $object
    )
        
    try {
        $curObj = GetOmadaObject -config $config -object $object
        $omadaObjectId = $curObj.Id
        if ($null -eq $curObj) {
            AddLog -msg ('Skipping update')
        }
        else {
            #apply delta
            foreach ($map in $config.map) {
                if ($null -ne $map.deltaOp -or $null -ne $map.deltaOpScript) {
                    $curvals = @($curObj.($map.targetProperty).Id)
                    $curvals = @($curObj.($map.targetProperty).($map.KeyProperty))
                    $addvals = @($object.data.('add#' + $map.targetProperty).Values)
                    $removevals = @($object.data.('remove#' + $map.targetProperty).Values)
                    $object.data.Remove('add#' + $map.targetProperty)
                    $object.data.Remove('remove#' + $map.targetProperty)

                    #current values as baseline for delta
                    $values = [System.Collections.ArrayList]@()
                    foreach ($v in $curvals) {
                        $values.Add((@{($map.KeyProperty) = $v }))
                    }

                    foreach ($v in $addvals) {
                        if ($null -ne $v) {
                            if ($values.Values -contains $v) {
                                AddLog -msg "Delta not applied, value is already present ($v)" 
                            }
                            else {
                                $values.Add(@{($map.KeyProperty) = $v })
                                AddLog -msg "Delta value added ($v)"
                            }
                        }
                    }
                    
                    foreach ($v in $removevals) {
                        if ($null -ne $v) {
                            if ($null -ne $v -and $values.Values -contains $v) {
                                $idx = -1
                                for ($i = 0; $i -lt $values.Count; $i++) {
                                    if ($values[$i].Values -eq $v) {
                                        $idx = $i
                                    }
                                }
                                if ($idx -ge 0) {
                                    $values.RemoveAt($idx)
                                }
                                AddLog -msg "Delta value removed ($v)"
                            }
                        }
                    }
                    $object.data.($map.targetProperty) = $values
                }
            }
            AddLog -msg ('Updating object')
            $null = $global:omadaHttp.ODataPUT($omadaObjectId, $config.object, $object.data)
        }
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'C'
    }
    catch {
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'E'
        HandleProcessingError -config $config -msg ('Error during update: ' + $_)
    }
}

function FastExecuteOmadaObject {
    param (
        [Parameter(Mandatory)]$config
        , [Parameter(Mandatory)]$httpmethod
        , [Parameter(Mandatory)]$objects
    )

    try {
        $requests = [System.Collections.ArrayList]@()

        foreach ($o in $objects) {
            $httpCfg = $global:omadaHttp.GetOmadaHttpConfig()            
            $url = $httpCfg.httpConfig.webprotocol + $httpCfg.httpConfig.webhost + '/OData/DataObjects/' + $config.object 
            if ($httpmethod.ToUpper() -in ('PUT', 'DELETE')) {
                $url += '(' + $o.identifier + ')'
            }

            $req = @{
                method         = $httpmethod
                url            = $url
                id             = 'ID:' + $o.identifier
                atomicityGroup = ('G' + $o.identifier)
                headers        = @{
                    'content-type'  = 'application/json'
                    'odata-version' = '4.0'
                }
            }

            if ($null -ne $o.data -and $o.data.Count -ne 0) {
                $req.body = $o.data
            }
            $null = $requests.Add($req)
        }

        $request = @{
            requests = $requests
        }

        StartBackgroundJob -request $request -maxConcurrentJobs $config.maxConcurrentJobs
        ProcessFinalizedJobs -config $config
    }
    catch {        
        HandleProcessingError -config $config -msg ('Error during job creation: ' + $_)
    }    
}

$global:FastExecuteObjectList = [System.Collections.ArrayList]@()

function CreateUpdateOmadaObject {
    param (
        $config
        , $object
    )
        
    try {
        $id = GetOmadaObjectId -config $config -object $object

        if ($null -eq $id) {
            AddLog -msg ('Creating object')
            $null = $global:omadaHttp.ODataPOST($config.object, $object.data)
            SetObjectImportStatus -config $config -identifier $object.identifier -status 'C' 
        }
        else {
            AddLog -msg ('Updating object')
            $null = $global:omadaHttp.ODataPUT($id, $config.object, $object.data)
            SetObjectImportStatus -config $config -identifier $object.identifier -status 'C'
        }
        AddLog -msg ('Object operation completed')
    }
    catch {
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'E'
        HandleProcessingError -config $config -msg ('Error during createupdate: ' + $_)
    }
}

function CreateIfNotExistsOmadaObject {
    param (
        $config
        , $object
    )
        
    try {
        $id = GetOmadaObjectId -config $config -object $object

        if ($null -eq $id) {
            AddLog -msg ('Creating object')            
            $null = $global:omadaHttp.ODataPOST($config.object, $object.data)
        }
        else {
            AddLog -msg ('Object already exists')
        }
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'C'
    }
    catch {
        SetObjectImportStatus -config $config -identifier $object.identifier -status 'E'
        HandleProcessingError -config $config -msg ('Error during createupdate: ' + $_)
    }
}

function TestOmadaObject {
    param (
        $config
        , $object
    )

    try {
        if ($null -ne $config.targetIdentifier -and $config.targetIdentifier.ToLower() -eq 'id') {
            $params = '(' + $object.identifier + ')?$select=Id'
            $res = $global:omadaHttp.ODataGET($config.object, $params)
            $id = $res.Id
        }
        else {
            $id = GetOmadaObjectId -config $config -object $object
        }
        
        if ($null -eq $id) {
            AddLog -msg ('Object not in Omada')
        }
        else {
            AddLog -msg ('Object exists')
        }

        $body = ConvertTo-Json -InputObject $object.data -Depth 10
        AddLog("Source data:`n" + $object.sourceData)
        AddLog("Body:`n" + $body)
    }
    catch {        
        HandleProcessingError -config $config -msg ('Error during test: ' + $_)
    }
}

function OPSAction {
    param (
        $config
        , $object
        , $action
    )

    $a = @{jobIds = @($object.data.jobid.Values) }
    $body = ConvertTo-Json $a -Depth 10
    $path = "/WebService/OPSWebServiceInternal.asmx/$action"
    $null = $global:omadaHttp.InvokeOmadaRestMethod('Post', $path, $body)    
}

function OPSReleaseJobs {
    param (
        $config
        , $object
    )
    $null = OPSAction -config $config -object $object -action 'MarkJobsAsReviewed'
}

function OPSArchiveJobs {
    param (
        $config
        , $object
    )
    $null = OPSAction -config $config -object $object -action 'ArchiveJobs'
}
function OPSRetryJobs {
    param (
        $config
        , $object
    )
    $null = OPSAction -config $config -object $object -action 'RetryJobs'
}

function ROPEQueueIdentites {
    param (
        $config
        , $object
    )
    
    $a = @{identityIds = @($object.data.IdentityId.Values) }
    $body = ConvertTo-Json $a -Depth 10
    $path = '/WebService/OIM_UIWebService.asmx/QueueIdentity'
    $null = $global:omadaHttp.InvokeOmadaRestMethod('Post', $path, $body)
}

function OPSSetSystemPreviewMode {
    Param(
        $config,
        $object
    )

    $res = $global:omadaHttp.ODataGet('System', '(' + $object.data.SystemId.Id + ')?$select=Id,Uid,DisplayName,OPSPROVISIONINGCONFIG')

    AddLog -msg ('Processing system: ' + $res.DisplayName + ', enable review mode:' + $object.data.Enable + ', commit:' + $object.data.Commit)
    [xml]$rx = $res.OPSPROVISIONINGCONFIG
    $settingChanged = $false
    $settingFound = $false
    foreach ($opsSetting in $rx.provisioningConfiguration.general.settings.setting) {
        if ($opsSetting.name -eq 'runInPreviewMode') {
            AddLog -msg ('Review mode: current value ' + $opsSetting.value)
            $settingFound = $true

            if ($opsSetting.value -eq $object.data.enable) {
                AddLog -msg 'Review mode already set, no change applied'
            }
            else {
                AddLog -msg 'Updating review mode setting'
                $settingChanged = $true
                
                $opsSetting.value = $object.data.enable.ToString()
                $body = @{
                    OPSPROVISIONINGCONFIG = $rx.OuterXml
                }            
                $null = $global:omadaHttp.ODataPut($res.Id, 'System', $body)
                
                AddLog -msg 'Update completed'
            }
        }
    }
    
    if (-not $settingFound) {
        AddLog -msg 'Review setting not found on system' -color Yellow
    }

    if (($settingChanged -and $object.data.commit) -or ($object.data.commit.ToString().ToLower() -eq 'force')) {
        AddLog -msg 'Committing OPS config for system'                    
        $body = @{
            systemUId = $res.UId
        }

        $body = convertto-json $body
        $r = $global:omadaHttp.InvokeOmadaRestMethod('POST', '/WebService/OPSWebServiceInternal.asmx/PushSystemConfiguration', $body)
        $r = ConvertFrom-json $r.d
        if ($r.success) {
            AddLog -msg 'Commit successful'
        }
        else {
            AddLog -msg 'Commit failed: ' + $r.message
        }
    }
    else {
        AddLog -msg 'Commit skipped'
    }
}

function OPSExpireClaim {
    Param(
        $config,
        $object
    )

    $body = '{"claims":{' + ($object.data.OPSClaim.keyValue -join ',') + '}}'
    $path = '/WebService/UIWebService.asmx/ExpireProvisioningClaimsAndRecalculateIdentities'
    $null = $global:omadaHttp.InvokeOmadaRestMethod('Post', $path, $body)
}

function CreateAccessRequest {
    Param(
        $config,
        $object
    )
    
    $variables = @{
        validFrom         = $object.data.ValidFrom
        validTo           = $object.data.ValidTo
        reason            = $object.data.Reason
        identityResources = @(
            @{
                resources = @{
                    id          = $object.data.ResourceUid
                    accountInfo = @{
                        accountTypeId = $object.data.AccountTypeUid
                        systemId      = $object.data.SystemUid
                    }
                }
                identity  = @{
                    id = $object.data.IdentityUid
                }
            }
        )
    }
    if ($null -ne $object.data.ContextUid -and $object.data.ContextUid -ne '') {
        $variables.context = $object.data.ContextUid
    }

    $body = @{
        operationName = 'createAccessRequest'
        query         = @'
mutation createAccessRequest($context: ID, $validFrom: DateTime, $validTo: DateTime, $identityResources: [IdentityResourcesInputType!]!, $reason: String) {
  createAccessRequest(
    accessRequest: {identityResources: $identityResources, reason: $reason, context: $context, validTo: $validTo, validFrom: $validFrom}
  )
}
'@
        variables     = $variables
    }

    $jsonbody = ConvertTo-Json $body -Depth 10
    $w = $global:omadaHttp.InvokeOmadaRestMethod('POST', '/api/domain/3.5', $jsonbody)

    if ($w.errors.Count -gt 0) {        
        throw "Error during access request creation: $($w.errors[0].message)"
    }
    else {
        AddLog -msg "Access request created with id: $($w.data.createAccessRequest)"
    }
}
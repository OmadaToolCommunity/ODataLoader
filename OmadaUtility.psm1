###################################################################################
# Omada utility
#
# Copyright (c) 2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

using module .\omadahttp.psm1
function Get-DOTSchema {
    param (
        [OmadaHttp]$config
    )

    $r = $config.InvokeOmadaWebMethod('Get', '/OData/DataObjects/$Metadata', $null, 'application/xml')

    $list = ([XML]($r.Content)).Edmx.DataServices.Schema.EntityType
    $res = @{}    

    foreach ($et in $list) {
        $props = @{}
        foreach ($prop in $et.Property) {
            $props.Add($prop.Name, $prop.Type)
        }
        $res.Add($et.Name, $props)
    }
    
    #OPSJob data type to support OPS operations
    $OPSJob = @{JobId = 'Collection(OIS.ReferenceValue)' }
    $res.Add('OPSJob', $OPSJob)
    
    #OPSClaim data type to support OPS operations
    $OPSClaim = @{OPSClaim = 'Collection(OIS.ReferenceValue)' }
    $res.Add('OPSClaim', $OPSClaim)

    # add ROPEQueing data type to support RoPE queing operations
    $RopeQ = @{IdentityId = 'Collection(OIS.ReferenceValue)' }
    $res.Add('ROPEQueing', $RopeQ)

    $SetSystemReviewMode = @{
        SystemId = 'Collection(OIS.ReferenceValue)'
        Enable   = 'Edm.Boolean'
        Commit   = 'Edm.String'
    }
    $res.Add('SystemReviewMode', $SetSystemReviewMode)
    
    $GraphQLAccessRequest = @{
        IdentityUid    = 'Edm.String'
        SystemUid      = 'Edm.String'        
        ResourceUid    = 'Edm.String'
        AccountTypeUid = 'Edm.String'
        ContextUid     = 'Edm.String'
        Reason         = 'Edm.String'
        ValidFrom      = 'Edm.DateTimeOffset'
        ValidTo        = 'Edm.DateTimeOffset'
    }
    $res.Add('GraphQLAccessRequest', $GraphQLAccessRequest)
    
    return $res
}


enum OmadaDatabases {
    ODW
    ODWS
    ODWMD
    OISES
    ROPE
    OPS
    ESARC
}

function QueryOmadaDatabase {
    param(
        [OmadaHttp]$omadaHttp,
        [OmadaDatabases]$db,
        $query
    )

    $qObjDef = @{
        name                                = 'AutomatedScriptQuery'
        C_SQLTROUBLESHOOTING_DATACONNECTION = @{
            KeyValue    = $db.ToString()
            KeyProperty = 'NAME'                                                
        }
        C_QUERY                             = $query
    }
    $qObj = ''
    $qObj = $omadaHttp.ODataPOST('C_P_SQLTROUBLESHOOTING', $qObjDef)
    
    $body = '{ "dataType":"SqlDataProducer", "dataTypeArgs": { "targetId": ' + $qObj.Id + ' }, "page":1, "rows":25, "sidx":null, "sord":"asc", "_search":false, "searchField":null, "searchString":null, "filters":null, "searchOper":null }'
    $path = '/webservice/JQGridPopulationWebService.asmx/GetPagingData'
    $resp = ""    
    
    $resp = $omadaHttp.InvokeOmadaRestMethod('POST', $path, $body)

    #clean up - remove sql object
    $qObj = $omadaHttp.ODataDELETE('C_P_SQLTROUBLESHOOTING', $qObj.Id)
    return $resp.d.Rows
}

function CreateSecretFile {
    param (
        [Parameter(Mandatory)][String]$filename,
        [Parameter(Mandatory)][String]$secret
    )
    ConvertTo-SecureString -String $secret -AsPlainText -Force | Convertfrom-securestring | Set-Content $filename
}
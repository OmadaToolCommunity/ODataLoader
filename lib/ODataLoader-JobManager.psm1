###################################################################################
# Omada ODataLoader - Concurrent jobs management
#
# Copyright (c) 2022,2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

$global:backgroundJobs = [System.Collections.ArrayList]@()
$r
function InitializeJobManager {
    $global:backgroundJobs = [System.Collections.ArrayList]@()
}

function StartBackgroundJob {
    param (
        [Parameter(Mandatory)]
        [Hashtable]$request,
        $maxConcurrentJobs = 5
    )

    if ($null -eq $maxConcurrentJobs) {
        $maxConcurrentJobs = 5
    }

    $notCompletedJobs = $global:backgroundJobs | Where-Object -Property State -notin ('Completed', 'Failed')

    while ($notCompletedJobs.Count -ge $maxConcurrentJobs) {
        AddLog -msg "Max concurrent job limit is reached, waiting for jobs to complete..."
        Start-Sleep -Seconds 5
        $notCompletedJobs = $global:backgroundJobs | Where-Object -Property State -notin ('Completed', 'Failed')
    }

    $mod = Get-Module -name 'omadahttp*'
    if ($mod.GetType().Name -eq 'Object[]') {
        $mod = $mod[0]
    }

    $modbase = $mod.ModuleBase
    $modname = $mod.Name
    $script = "using module '$modbase\$modname.psm1'"
    $script +=
    @'      
    
    Param(
        [Parameter(Mandatory)]
        $scriptRoot,
        [Parameter(Mandatory)]
        $omadaHttpCfg,
        [Parameter(Mandatory)]
        $request
    )

    $request=(ConvertTo-JSON -Depth 10 -InputObject ($request))

    try
    {
        $objname="$" + "batch"   
        $omadaHttp=[OmadaHttp]::new($omadaHttpCfg.httpConfig,$omadaHttpCfg.OAuthBearerToken)
        $resp=$omadaHttp.ODataPOST($objname,$request)
    }
    catch
    {
        Write-Host "Error in background job:" $_
    }    
    return $resp
'@

    $scriptBlock = [ScriptBlock]::Create($script)
    $httpCfg = $global:omadaHttp.GetOmadaHttpConfig()
    $job = Start-Job -ArgumentList $PSScriptRoot, $httpCfg, $request -ScriptBlock $scriptBlock
    AddLog -msg ('Job ' + ($job.Id) + ' started')
    $global:backgroundJobs.Add($job)
}

function GetJobResult {
    param (
        $job    
    )

    return $job | Receive-Job
}
function RemoveJob {
    param (
        $job
    )
    Remove-Job -Job $job -ErrorAction SilentlyContinue
    $global:backgroundJobs.Remove($job)
}

function ProcessFinalizedJobs {
    param (
        [Parameter(Mandatory)]$config
    )
    
    $finalizedJobs = $global:backgroundJobs | Where-Object -Property State -in ('Completed', 'Failed')
    AddLog -msg ("$($finalizedJobs.Count) jobs completed")

    foreach ($job in $finalizedJobs) {
        if ($job.State -eq 'Completed') {
            AddLog -msg ('Job ' + $Job.Id + ' completed, processing result')
            $res = GetJobResult -job $job
            foreach ($r in $res.responses) {        
                $identifier = $r.id.Substring(3)
                if ($r.status -ge 200 -and $r.status -lt 300) {
                    AddLog ('Operation on ' + $identifier + ' completed')
                    SetObjectImportStatus -config $config -identifier $identifier -status 'C'
                }
                else {
                    AddLog -msg ('Operation on ' + $r.id + ' failed: ' + $r.body.error.message) -color Red
                    SetObjectImportStatus -config $config -identifier $identifier -status 'E'            
                }
            }
        }
        else {
            $res = GetJobResult -job $job
            AddLog -msg ('Job ' + $Job.Id + ' failed: ' + $res) -color Red            
        }
        RemoveJob -job $job
    }
}

function WaitForJobCompletion {
    param (
        $config
    )

    while ($global:backgroundJobs.Count -gt 0) {
        AddLog -msg ('Waiting for ' + $global:backgroundJobs.Count + ' jobs to complete')
        Start-Sleep -Seconds 5
        ProcessFinalizedJobs -config $config
    }
}
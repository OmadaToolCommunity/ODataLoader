###################################################################################
# Omada ODataLoader - Logging and progress tracking
#
# Copyright (c) 2022,2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

function InitLog {
    param(
        $logPath,
        $maxLogFiles = 10
    )
    
    $maxLogFiles++

    $global:logpath = $logPath
    $null = New-Item $logpath -ItemType 'Directory' -ErrorAction SilentlyContinue
    $global:logfile = $logpath + '\' + (Get-Date -Format 'yyyyMMddHHmmss') + '.log'
    Add-Content -Path $global:logfile -Value 'Log initialized'
    AddLog -msg 'Log initialized'

    if ($null -ne $maxLogFiles) {
        $logfiles = Get-ChildItem -Path $logPath -Filter '*.log' | Sort-Object -Property CreationTime
        for ($i = 0; $i -le $logfiles.Count - $maxLogFiles; $i++) {
            Write-Host 'Removing log file' $logfiles[$i].Name
            Remove-Item -Path $logfiles[$i].FullName
        }
    }    
}

enum LogLevel {
    IDENTIFIER
    INFO
    WARNING
    ERROR
}

function AddLog {
    param (
        [Parameter(Mandatory)]
        $msg,
        [System.ConsoleColor]$color = [System.ConsoleColor]::White,
        [LogLevel]$Level = [LogLevel]::INFO
    )

    $d = Get-Date -Format 'dd-MM-yyyy HH:mm:ss.fff'
    $l = "$Level".PadRight(10, ' ')
    Write-host $d $msg -foregroundcolor $color
    Add-Content -Path $global:logfile -Value "$d $msg"
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

function InitializeObjectImportStatusList {
    param (
        $config
    )
    
    $global:ImportStatusList = @{}
    
    if (-not $config.progressTracking) {
        return
    }

    if (Test-Path -Path ($global:logpath + '/' + $config.ID + '.wmkold') -PathType Leaf) {
        throw "Inconsistent progress tracking detected, pls. resolve before running operation"
    }

    if (-not (Test-Path ($global:logpath + '/' + $config.ID + '.wmk'))) {
        Add-Content -Path ($global:logpath + '/' + $config.ID + '.wmk') -Value '"status";"identifier"'
    }
    
    $values = Import-Csv -Path ($global:logpath + '/' + $config.ID + '.wmk') -Delimiter ';' -Encoding UTF8
    foreach ($v in $values) {        
        $global:ImportStatusList[$v.identifier] = ($v.status)
    }    
}
function GetObjectImportStatus {
    param(
        $identifier
    )

    return $global:ImportStatusList[$identifier]
}

function SetObjectImportStatus {
    param(
        $config,
        $identifier,
        $status
    )
    
    if (-not $config.progressTracking) {
        return
    }

    $global:ImportStatusList[$identifier] = $status
    New-Object PSObject -property @{ status = ($status); identifier = ($identifier) } | Export-Csv -NoTypeInformation -Delimiter ';' -Path ($global:logpath + '/' + $config.ID + '.wmk') -Encoding UTF8 -Append
}

function SaveObjectImportStatusList {
    param (
        $config
    )
    
    if (-not $config.progressTracking) {
        return
    }

    AddLog -msg 'Saving object import status'
    Rename-Item -Path ($global:logpath + '\' + $config.ID + '.wmk')  -NewName ($config.ID + '.wmkold')
    $global:ImportStatusList.GetEnumerator() | Select-Object Key, Value | foreach-Object { New-Object PSObject -property @{ identifier = ($_.Key); status = ($_.Value) } } | Export-Csv -NoTypeInformation -Delimiter ';' -Path ($global:logpath + '/' + $config.ID + '.wmk') -Encoding UTF8
    Remove-Item ($global:logpath + '/' + $config.ID + '.wmkold') -Force -ErrorAction SilentlyContinue 
}
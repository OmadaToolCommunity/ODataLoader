###################################################################################
# Omada ODataLoader - Data object builder
#
# Copyright (c) 2022,2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

function CombineObjects {
    param (
        [Parameter(Mandatory)]
        $config,
        [Parameter(Mandatory)]
        $obj1,
        [Parameter(Mandatory)]
        $obj2
    )

    foreach ($attrMap in $config.map) {   
        $dataType = $global:DOTSchema.($config.object).($attrMap.targetProperty)
        $v1 = $obj1.data.($attrMap.targetProperty)
        $v2 = $obj2.data.($attrMap.targetProperty)

        if ($dataType -eq 'Collection(OIS.ReferenceValueWithAttributes)') {
            $attrvals = [System.Collections.ArrayList]@()
            foreach ($v1item in $v1) {
                $attrvals.Add($v1item)

                $isduplicate = $false
                foreach ($v2item in $v2) {
                    if ($v1item.Id -eq $v2item.Id) {
                        $isduplicate = $true
                        $val1 = $v1item.AttributeValues.Value.ValueText
                        $val2 = $v2item.AttributeValues.Value.ValueText
                        if ($val1 -ne $val2) {
                            AddLog -msg ('Duplicate attribute found during object combine. Attributes can only be defined once on an object, attribute name: ' + $v2item.DisplayName) -color Yellow    
                        }
                    }
                }
                if (-not $isduplicate) {
                    $attrvals.Add($v2item)
                }
            }
            $v1 = $attrvals
        }
        elseif ($dataType -eq 'Collection(OIS.ReferenceValue)') {
            $targetPropName = $attrMap.targetProperty
            if ($null -ne $attrMap.deltaOp -or $null -ne $attrMap.deltaOpScript) {
                $targetPropName1 = 'add#' + $attrMap.targetProperty
                $targetPropName2 = 'remove#' + $attrMap.targetProperty

                if ($obj2.data.ContainsKey($targetPropName1)) {
                    $targetPropName = $targetPropName1
                }
                elseif ($obj2.data.ContainsKey($targetPropName2)) {
                    $targetPropName = $targetPropName2
                }
                else {
                    throw 'delta err'
                }

                $v1 = $obj1.data.($targetPropName)
                $v2 = $obj2.data.($targetPropName)
            }
            if ($null -eq $v1) {
                $v1 = [System.Collections.ArrayList]@()
            }

            if ($attrMap.KeyProperty.Tolower() -eq 'id') {
                $valueIdentifier = 'Id'
            }
            elseif ($attrMap.KeyProperty.Tolower() -eq 'uid') {
                $valueIdentifier = 'UId'
            }
            else {
                $valueIdentifier = 'KeyValue';    
            }            

            $newValue = $v2[0].$valueIdentifier;
            $isPresent = $false
            foreach ($elem in $v1) {
                $isPresent = $isPresent -or ($newValue -eq $elem.$valueIdentifier)
            }

            if (-not $isPresent) {
                if ($attrMap.KeyProperty.ToLower() -eq 'id') {
                    $valueIdentifier = 'Id'
                    $v1.Add( @{
                            Id = [int]$newValue
                        }
                    )
                }
                elseif ($attrMap.KeyProperty.ToLower() -eq 'uid') {
                    $valueIdentifier = 'UId'
                    $v1.Add( @{
                            UId = $newValue
                        }
                    )
                }
                else {
                    $v1.Add( @{
                            KeyProperty = $attrMap.KeyProperty
                            KeyValue    = $newValue
                        }
                    )
                }
                $obj1.data.($targetPropName) = $v1
            }
        }
        elseif ($dataType -eq 'Collection(OIS.SetValue)') {
            foreach ($nv in $v2) {
                $newValue = $nv.Value;
                $isPresent = $false
                foreach ($elem in $v1) {
                    $isPresent = $isPresent -or ($newValue -eq $elem.Value)
                }

                if (-not $isPresent) {
                    $v1.Add(@{Value = $newValue })
                    $obj1.data.($attrMap.targetProperty) = $v1
                }
            }
        }
        else {
            if ($dataType -eq 'OIS.ReferenceValue') {
                $v1 = $v1.KeyValue
                $v2 = $v2.KeyValue
            }
            if ($dataType -eq 'OIS.SetValue') {
                $v1 = $v1.Value
                $v2 = $v2.Value
            }

            if ($v1 -ne $v2) {
                AddLog -msg ('Warning: different values found for single value property during combine of target property ' + $attrMap.targetProperty) -color Yellow
                AddLog -msg ('Value 1 ' + (ConvertTo-Json $v1))  -color Yellow
                AddLog -msg ('Value 2 ' + (ConvertTo-Json $v2))  -color Yellow
            }
        }
    }
    return $obj1
}

$global:DOTSchema = $null

function GetObjectIdentifier {
    param (
        [Parameter(Mandatory)]
        $config,
        [Parameter(Mandatory)]
        $record
    )

    if ($null -ne $config.sourceIdentifier) {
        return ($record.($config.sourceIdentifier))
    }
    elseif ($null -ne $config.sourceIdentifierScript) {
        $sb = [ScriptBlock]::Create($config.sourceIdentifierScript)
        return Invoke-Command -ScriptBlock $sb -ArgumentList @($record)
    }
    else {
        throw 'No source identifier defined in configuration'
    }
}

function BuildQueryParams {
    param (
        [Parameter(Mandatory)]
        $objectResolver,
        [Parameter(Mandatory)]
        $record
    )

    $params = '?$filter='

    $tokens = $objectResolver.queryFilter -split '{'
    foreach ($token in $tokens) {
        $t = $token -split '}'
        if ($t.Count -eq 2) {
            $v = $record.($t[0])
            if ($null -eq $v) {
                throw ('Error in resolver "' + $objectResolver.name + '", unable to resolve value for parameter ' + $t[0] + ' in query string')
            }
            $escval = [uri]::EscapeDataString($v.ToString())
            $params += $escval + $t[1]
        }
        else {
            $params += $token
        }
    }
    $params += '&$select=' + $objectResolver.queryProperty
    return $params
}

$global:CSVResolverCache = @{}

function ResolveValuesFromCSV {
    param (
        $resolverConfig,
        [Parameter(Mandatory)]
        $record
    )

    if ($null -eq $global:CSVResolverCache.($resolverConfig.sourcefile)) {
        $v = Import-Csv -Path $resolverConfig.sourcefile -Delimiter $resolverConfig.sourceDelimiter -Encoding utf8
        $global:CSVResolverCache.($resolverConfig.sourcefile) = $v
    }

    $v1 = $global:CSVResolverCache.($resolverConfig.sourcefile).($resolverConfig.lookupColumn)
    $lkupval = $record.($resolverConfig.lookupProperty)
    if ($resolverConfig.IgnoreCase) {
        $v1 = $v1.Foreach({ if ($null -ne $_ ) { $_.ToLower() } })
        $lkupval = $lkupval.ToLower()
    }
    $idx = $v1.indexOf($lkupval)
    if ($idx -eq -1) {
        $d = '(Column: "' + $resolverConfig.lookupColumn + '" - value: "' + $lkupval + '" - file:' + $resolverConfig.sourcefile + ')'
        switch (('' + $resolverConfig.notFoundAction).ToLower()) {
            'ignore' {
                if ($resolverConfig.logNoMatch) {
                    AddLog -msg ('csvResolver "' + $resolverConfig.name + '": No match when mapping value from file. ' + $d)
                }
            }
            'halt' { throw 'csvResolver "' + $resolverConfig.name + '": Unresolved value, halting. ' + $d }
            default { throw 'csvResolver "' + $resolverConfig.name + '": Unsupported "notFoundAction". ' + $d }
        }
    }
    else {
        $val = $global:CSVResolverCache.($resolverConfig.sourcefile).($resolverConfig.valueColumn)[$idx]
        if ($resolverConfig.logMatch) {
            AddLog -msg $('csvResolver: Mapping value"' + $val + '" from file ' + $resolverConfig.sourcefile)
        }
        if ($null -eq $record.($resolverConfig.valueProperty)) {
            Add-Member -InputObject $record -name $resolverConfig.valueProperty -Value $val -MemberType NoteProperty
        }
        else {
            $record.($resolverConfig.valueProperty) = $val
        }
    }
    return $true
}


$global:ObjectResolverCache = @{}

function ResolveValuesFromOmadaObjects { 
    param (
        $resolverConfig,
        [Parameter(Mandatory)]
        $record
    )

    $params = BuildQueryParams -objectResolver $resolverConfig -record $record
    if ($resolverConfig.detailedLog) {
        AddLog -msg (' - ' + $resolverConfig.name + ' query params: ' + $params) -color DarkBlue
    }

    $res = $global:ObjectResolverCache.($resolverConfig.queryDOT + ':' + $params)
    if ($null -ne $res) {
        if ($resolverConfig.detailedLog) {
            AddLog -msg (' - ' + $resolverConfig.name + ' value resolved from cache') -color DarkBlue
        }            
        Add-Member -InputObject $record -Name $resolverConfig.valueProperty -Value $res -MemberType NoteProperty -Force
    } 
    else {
        $res = $global:omadahttp.ODataGET($resolverConfig.queryDOT, $params)
        if ($resolverConfig.detailedLog) {
            $q = ConvertTo-Json -InputObject $res.value
            AddLog -msg (' - ' + $resolverConfig.name + ' resolved from OData query: ' + $q) -color DarkBlue
        }

        if ($res.value.Count -eq 0) {
            if ($resolverConfig.SkipNotFound) {
                AddLog('Skipping record in object resolver ' + $resolverConfig.name + ': No Data Object resolved by query: ' + $params) -color DarkGreen
            }
            else {
                AddLog('Error in object resolver ' + $resolverConfig.name + ': No Data Object resolved by query: ' + $params) -color Red
                return $false
            }
        }
        elseif ($res.value.Count -eq 1) {
            $p = $resolverConfig.valueProperty
            $v = $res.value.($resolverConfig.queryProperty)
            if ($resolverConfig.detailedLog) {
                AddLog -msg (' - ' + $resolverConfig.name + ' resolved one value as required, storing in "' + $p + '", value: "' + $b + '"') -color DarkBlue
            }
            $global:ObjectResolverCache.($resolverConfig.queryDOT + ':' + $params) = $res.value.($resolverConfig.queryProperty)
            Add-Member -InputObject $record -Name $p -Value $v -MemberType NoteProperty -Force
        }
        else {
            AddLog ('Error in object resolver ' + $resolverConfig.name + ': More than one Data Object resolved by query: ' + $params) -color Red
            return $false
        }    
    }
    return $true
}
function preProcess {
    param (
        [Parameter(Mandatory)]
        $config,        
        [Parameter(Mandatory)]
        $record
    )

    foreach ($preprocesscfg in $config.preProcessing) {
        switch ($preprocesscfg.processingType) {
            'csvResolver' {
                $res = ResolveValuesFromCSV -resolverConfig $preprocesscfg -record $record
            }
            
            'odataResolver' {
                $res = ResolveValuesFromOmadaObjects -resolverConfig $preprocesscfg -record $record
            }

            'script' {
                $sb = [ScriptBlock]::Create($preprocesscfg.script)
                try {
                    $res = Invoke-Command -ScriptBlock $sb -ArgumentList @($record)                    
                }
                catch {
                    AddLog -msg ('Error in script resolver "' + ($preprocesscfg.Name) + '"') -color red
                    throw $_
                }
                Add-Member -InputObject $record -Name $preprocesscfg.valueProperty -Value $res -MemberType NoteProperty -Force
                $res = $true
            }

            Default {
                Throw ('Unknown preprocessing type in definition with name: "' + $preprocesscfg.name + '"')
            }
        }
        if (-not $res) { return $false }
    }
    return $true
}

function BuildObject {
    param (
        [Parameter(Mandatory)]
        $config,        
        [Parameter(Mandatory)]
        $record,
        [Parameter(Mandatory)]
        $res
    )
    
    $resolveRes = preProcess -config $config -record $record    
    if (-not $resolveRes) {
        #AddLog ('Error in object resolver: aborting object processing') -color Red
        $res.identifier = $null
        return $false
    }
    
    $res.identifier = GetObjectIdentifier -config $config -record $record

    foreach ($attrMap in $config.map) {
        if ($null -ne $attrMap.const) {
            $value = $attrMap.const
        }
        else {
            $value = $record.($attrMap.sourceProperty)
            if ($value -eq '' -and $null -ne ($attrMap.defaultValue)) {
                $value = $attrMap.defaultValue 
            }
        }
        
        #remove 0x00 in values in strings, as they will cause an error in OData
        #and add pre/post fix values
        if ($null -ne $value -and $value.GetType() -eq [System.String]) {
            $value = $value.Replace("`0", "")
        }

        if ($null -ne $attrMap.sourceScript) {
            $s = 'param($record);' + $attrMap.sourceScript
            $sb = [ScriptBlock]::Create($s)
            $value = Invoke-Command -ScriptBlock $sb -ArgumentList @($record)
        }
        
        $deltaOp = $null
        if ($null -ne $attrMap.deltaOpScript) {
            $s = 'param($record);' + $attrMap.deltaOpScript
            $sb = [ScriptBlock]::Create($s)
            $deltaOp = Invoke-Command -ScriptBlock $sb -ArgumentList @($record)
            $deltaOp = $deltaOp.ToLower()
        }
        elseif ($null -ne $attrMap.deltaOp) {
            $deltaOp = $attrMap.deltaOp.ToLower();
        }

        if ($null -ne $deltaOp -and $deltaOp.ToLower() -notin @('add', 'remove')) {
            throw 'Delta operation was "' + $deltaOp + '" must be either "Add" or "Remove" in mapping of target property: ' + $attrmap.targetProperty
        }        

        if ($null -eq $global:DOTSchema.($config.object)) {
            $pp = '"' + $config.object + '"'
            throw ('Unknown target object type: ' + ($pp) + ' - is the DOT enabled for OData?')
        }

        $dataType = $global:DOTSchema.($config.object).($attrMap.targetProperty)
        if ($null -eq $dataType) {
            $pp = '"' + $attrMap.targetProperty + '"'
            throw ('Unknown target property: ' + ($pp))
        }
        
        if ($dataType -eq 'OIS.SetValue') {
            if ($value -eq '') {
                $value = $null
            }
            else {
                $value = @{Value = $value }
            }
        }
        elseif ($dataType -eq 'Collection(OIS.SetValue)') {
            if ($value -eq '') {
                $value = $null
            }
            else {
                $vb = [System.Collections.ArrayList]@()
                foreach ($v in $value) {
                    $vb.Add(@{Value = $v })
                }
                $value = $vb
            }
        }
        elseif ($dataType -eq 'Edm.Boolean') {
            if ($null -eq $value) {
                throw ('Unsupported boolean value: "' + $value + '" for source property ' + $attrMap.sourceProperty + '. Use 0/1 or false/true')
            }
            elseif ($value -eq '1' -or ('' + $value).ToLower() -eq 'true') {
                $value = $true
            }
            elseif ($value -eq '0' -or ('' + $value).ToLower() -eq 'false') {
                $value = $false
            }
            else {
                throw ('Unsupported boolean value: "' + $value + '" for source property ' + $attrMap.sourceProperty + '. Use 0/1 or false/true')
            }
        }
        elseif ($dataType -eq 'Edm.DateTimeOffset') {   
            try {   
                if ($null -eq $attrMap.inputdateformat) {
                    AddLog -msg ('Error, Missing inputdateformat on ' + $attrMap.targetProperty)
                    exit
                }
                elseif ($value -eq '') {
                    $value = $null
                }
                else {      
                    $value = [datetime]::ParseExact($value, $attrMap.inputdateformat, $null)
                    $value = $value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
                }
            }
            catch {                
                HandleProcessingError -config $config -msg ('Error during date parsing of property: ' + $attrMap.sourceProperty + ' value:' + $value)
                return $null
            }
        }        
        elseif ($dataType -eq 'Collection(OIS.ReferenceValue)') {
            if ($null -eq $attrMap.KeyProperty) {
                AddLog -msg ('Error, Missing KeyProperty on ' + $attrMap.targetProperty) -color Red
                exit
            }
            else {
                if ($value -eq '') {
                    $value = @()
                }
                else {
                    $vb = [System.Collections.ArrayList]@()
                    foreach ($e in $value) {
                        if ($attrMap.KeyProperty.ToLower() -eq 'id') {
                            $vb.Add(@{Id = [int]$e })
                        }
                        elseif ($attrMap.KeyProperty.ToLower() -eq 'uid') {
                            $vb.Add(@{UId = $e })
                        }
                        else {
                            $vb.Add(@{
                                    KeyProperty = $attrMap.KeyProperty
                                    KeyValue    = $e
                                })
                        }
                    }
                    $value = $vb
                }
            }
        }
        elseif ($dataType -in @('OIS.ReferenceValue', 'OIS.IDENTITYREF')) {
            if ($null -eq $attrMap.KeyProperty) {
                AddLog -msg ('Error, Missing KeyProperty on ' + $attrMap.targetProperty) -color Red
                exit
            }            
            else {
                if ($value -eq '') {
                    $value = @{}
                }
                elseif ($attrMap.KeyProperty.ToLower() -eq 'id') {
                    $value = @{
                        Id = [int]$value
                    }
                }                
                elseif ($attrMap.KeyProperty.ToLower() -eq 'uid') {
                    $value = @{
                        UId = $value
                    }
                }
                else {
                    $value = @{
                        KeyProperty = $attrMap.KeyProperty
                        KeyValue    = $value
                    }
                }
            }
        }
        elseif ($dataType -eq 'Collection(OIS.ReferenceValueWithAttributes)') {
            if ($null -eq $attrMap.KeyProperty) {
                AddLog -msg ('Error, Missing KeyProperty on ' + $attrMap.targetProperty) -color Red
                exit
            }
            else {
                $vb = $res.data.ATTRIBVALUES
                if ($null -eq $vb) {
                    $vb = [System.Collections.ArrayList]@()
                }

                $rescfg = @{
                    queryDOT       = "Attribute"
                    queryFilter    = "NAME eq '$($record.($attrMap.KeyProperty))'"
                    queryProperty  = "Id"
                    valueProperty  = "##InternalResolvedAttributeId"
                    notFoundAction = "ignore"
                }
                
                $null = ResolveValuesFromOmadaObjects -resolverConfig $rescfg -record $record

                foreach ($e in $value) {
                    $vb.Add(@{
                            Id              = $record.('##InternalResolvedAttributeId')
                            DisplayName     = $record.($attrMap.KeyProperty)
                            AttributeValues = @(
                                @{
                                    Name  = 'ATTRIBVALUE'
                                    Value = @{
                                        valueText = $e
                                    }
                                }
                            )
                        })
                }
                $value = $vb                
            }
        }

        if ((($null -eq $value) -or ($value -eq '')) -and $attrMap.required) {
            AddLog ('Error, required source property "' + $attrMap.sourceProperty + '" is empty')			
            return $null
        }
        elseif ($null -ne $value) {
            if ($null -ne $deltaOp) {
                $propName = $deltaOp + '#' + ($attrMap.targetProperty)
            }
            else {
                $propName = $attrMap.targetProperty
            }
            $res.data.$propName = $value
        }        
    }
}

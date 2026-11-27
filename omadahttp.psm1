###################################################################################
# Omada OData http
#
# Copyright (c) 2022,2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

$r = Get-InstalledModule
if (('MSAL.PS' -notin $r.name) -or ($null -eq $r)) {
    Install-Module -Name MSAL.PS -Repository PSGallery
}
if (('microsoft.graph.authentication' -notin $r.name) -or ($null -eq $r)) {
    Install-Module -Name microsoft.graph.authentication -Repository PSGallery
}

import-module MSAL.PS
import-module microsoft.graph.authentication

class OmadaHttpConfiguration {
    hidden [PSObject]$httpConfig = $null
    hidden $OAuthToken = $null
    hidden $OAuthApplication = $null
    hidden $OAuthBearerToken = $null

    OmadaHttpConfiguration (
        [OmadaHttpConfiguration]$httpConfig
    ) {
        $this.httpConfig = $httpConfig.httpConfig
    }
    
    OmadaHttpConfiguration (
        [PSObject]$httpConfig
    ) {
        $this.httpConfig = $httpConfig
    }

    SetStaticBearerToken([String]$token) {
        $this.OAuthBearerToken = $token
    }
    
    [String]GetStaticBearerToken() {
        return $this.OAuthBearerToken
    }
}

class OmadaHttp {
    hidden [OmadaHttpConfiguration]$omadaHttpConfig = $null
    hidden $WebSession = $null
    
    OmadaHttp(        
        [PSCustomObject]$httpConfig
    ) {
        $this.omadahttpConfig = [OmadaHttpConfiguration]::new($httpConfig)        
    }

    OmadaHttp([OmadaHttpConfiguration]$omadaHttpConfiguration) {
        $this.omadaHttpConfig = $omadaHttpConfiguration
    }

    OmadaHttp(
        [PSCustomObject]$httpConfig,
        [String]$staticBearerToken
    ) {
        $this.omadahttpConfig = [OmadaHttpConfiguration]::new($httpConfig)
        $this.omadahttpConfig.SetStaticBearerToken($staticBearerToken)
    }

    [OmadaHttpConfiguration]GetOmadaHttpConfig() {        
        $cfg = [OmadaHttpConfiguration]::new($this.omadaHttpConfig)

        #if using bearer tokens then populate with a fresh token
        #to be used when running in another job
        switch ($this.omadaHttpConfig.httpConfig.authentication) {

            'OAuthAzureADClientCredentials' {
                $token = $this.GetAuthTokenClientCredentialsAzureAD()
                $cfg.SetStaticBearerToken($token)
            }

            default {
            }    
        }

        return $cfg
    }
    
    SetOmadaHttpConfig([OmadaHttpConfiguration]$omadaHttpCfg) {
        $this.omadaHttpConfig = $omadaHttpCfg
    }

    WriteHttpLog([string]$logText) {
        if ($this.omadaHttpConfig.httpConfig.httpDetailedLogging) {
            write-host (Get-Date -Format 'dd-MM-yyyy HH:mm:ss.fff') $logText -ForegroundColor Gray
        }
    }

    hidden [Object]GetAuthTokenClientCredentialsAzureAD() {
        if (('' -ne $this.omadaHttpConfig.GetStaticBearerToken()) -and ($null -eq $this.omadaHttpConfig.OAuthToken)) {
            #cached token is defined and no session defined (used when http config is passed to a another process for threading)
            return $this.omadaHttpConfig.GetStaticBearerToken()
        }

        if (($null -ne $this.omadaHttpConfig.OAuthToken) -and ($this.omadaHttpConfig.OAuthToken.ExpiresOn.LocalDateTime -gt ( Get-Date) )) {
            $this.WriteHttpLog('Reuse token')
            return $this.omadaHttpConfig.OAuthToken.CreateAuthorizationHeader()
        }
        else {
            $this.WriteHttpLog('New token')

            #load and decrypt client secret
            $SecurePassword = get-Content $this.omadaHttpConfig.httpConfig.OAuthAzureADClientCredentials.oauthClientSecretFile | ConvertTo-SecureString           

            $this.omadaHttpConfig.OAuthToken = $null
            $this.omadaHttpConfig.OAuthToken = Get-MsalToken -TenantId $this.omadaHttpConfig.httpConfig.OAuthAzureADClientCredentials.oauthTenantId `
                -ClientId $this.omadaHttpConfig.httpConfig.OAuthAzureADClientCredentials.oauthClientId `
                -ClientSecret $SecurePassword `
                -Scopes $this.omadaHttpConfig.httpConfig.OAuthAzureADClientCredentials.oauthScope
            
            $this.WriteHttpLog('Token expiry: ' + $this.omadaHttpConfig.OAuthToken.ExpiresOn.LocalDateTime)
            
            $token = $this.omadaHttpConfig.OAuthToken.CreateAuthorizationHeader()
            return $token
        }
    }

    [PSObject]InvokeIntegrated([string]$method, [string]$uri, [Object]$body, [string]$contentType) {
        $url = $this.omadaHttpConfig.httpConfig.webprotocol + $this.omadaHttpConfig.httpConfig.webhost + $uri
        $this.WriteHttpLog('URL: ' + $url)
        $this.WriteHttpLog('Body: ' + $body)
        if ($null -eq $this.WebSession) {
            $url1 = $this.omadaHttpConfig.httpConfig.webprotocol + $this.omadaHttpConfig.httpConfig.webhost
            $session = $null
            $null = Invoke-WebRequest -Uri $url1 -Method Get -UseDefaultCredentials `
                -TimeoutSec $this.omadaHttpConfig.httpConfig.timeoutSec -ErrorVariable httperr -SessionVariable session
            $this.WebSession = $session
        }

        $httperr = ''
        if ($body -eq '') {
            $body = $null
        }
        $resp = Invoke-WebRequest -Uri $url -Method $method -Body $body -ContentType $contentType `
            -Headers @{'Accept' = $contentType } `
            -UseDefaultCredentials `
            -TimeoutSec $this.omadaHttpConfig.httpConfig.timeoutSec `
            -WebSession $this.WebSession `
            -ErrorVariable httperr            
        return $resp
    }

    [PSObject]InvokeOAUTHClientCredentials([string]$method, [string]$uri, [Object]$body, [string]$contentType) {
        if ($body -eq '') {
            $body = $null
        }

        $token = $this.GetAuthTokenClientCredentialsAzureAD()
        $this.WriteHttpLog($token)

        if ($null -eq $this.WebSession) {
            $url1 = $this.omadaHttpConfig.httpConfig.webprotocol + $this.omadaHttpConfig.httpConfig.webhost
            $session = $null            
            $null = Invoke-WebRequest -Uri $url1 -Method $method -Body $body -ContentType $contentType -Headers @{'Accept' = $contentType ; 'Authorization' = $token } -TimeoutSec $this.omadaHttpConfig.httpConfig.timeoutSec -ErrorVariable httperr -SessionVariable session
            $this.WebSession = $session
        }

        $url = $this.omadaHttpConfig.httpConfig.webprotocol + $this.omadaHttpConfig.httpConfig.webhost + $uri
        $this.WriteHttpLog('URL: ' + $url)
        $this.WriteHttpLog('Body: ' + $body)

        $httperr = ''
        $res = Invoke-WebRequest -Uri $url -Method $method -Body $body -ContentType $contentType `
            -Headers @{'Accept' = $contentType ; 'Authorization' = $token } `
            -WebSession $this.WebSession -TimeoutSec $this.omadaHttpConfig.httpConfig.timeoutSec `
            -ErrorVariable httperr
        return $res
    }

    [PSObject]InvokeCookie([string]$method, [string]$uri, [Object]$body, [string]$contentType) {
        if ($body -eq '') {
            $body = $null
        }
        if ($contentType -eq '') {
            $contentType = $null
        }

        if ($null -eq $this.WebSession) {
            $cookieList = @(
                @{name = "oisauthtoken"; value = $this.omadaHttpConfig.httpConfig.Cookie.cookie }
            )
            $this.WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            foreach ($ck in $cookieList) {
                $cookie = New-Object System.Net.Cookie
                $cookie.Domain = $this.omadaHttpConfig.httpConfig.webhost
                $cookie.Name = $ck.name
                $cookie.Value = $ck.value
                $this.WebSession.Cookies.Add($cookie);
            }
        }

        $url = $this.omadaHttpConfig.httpConfig.webprotocol + $this.omadaHttpConfig.httpConfig.webhost + $uri
        $this.WriteHttpLog('URL: ' + $url)
        $this.WriteHttpLog('Body: ' + $body)
        
        $httperr = ''
        return Invoke-WebRequest -Uri $url -Method $method -Body $body -ContentType $contentType `
            -Headers @{'Accept' = '*/*' } -WebSession $this.WebSession `
            -TimeoutSec $this.omadaHttpConfig.httpConfig.timeoutSec -ErrorVariable httperr
    }

    [PSObject]InvokeBrowserInteractive([string]$method, [string]$uri, [Object]$body, [string]$contentType) {
        if ($null -eq $this.WebSession) {
            $cookie = $this.GetCookieBrowserInteractive()
            $this.omadaHttpConfig.httpConfig.Cookie = @{cookie = $cookie }
        }
        
        try {
            return $this.InvokeCookie($method, $uri, $body, $contentType)
        }
        catch {
            $ex = $_
            $sc = $ex.exception.StatusCode.value__

            if ($sc -eq 401) {
                #unauthorized, need to login again
                $this.WebSession = $null
                $cookie = $this.GetCookieBrowserInteractive()
                $this.omadaHttpConfig.httpConfig.Cookie = @{cookie = $cookie }
                return $this.InvokeCookie($method, $uri, $body, $contentType)                
            }
        }
        throw "Unable to process http request $uri" + $ex
    }
    
    [String]GetCookieBrowserInteractive() {
        
        $chromepath = (Get-Item (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe').'(Default)')
        $chromeversion = $chromepath.VersionInfo.FileVersion
        $ChromeVersion = $ChromeVersion.Substring(0, $ChromeVersion.LastIndexOf("."));

        $chromedriverfile = "$PSScriptRoot\lib\chromedriver-win64\chromedriver.exe"
        $driverVersion = $null
        if (Test-Path $chromedriverfile) {
            $driverVersion = (Get-Item $chromedriverfile).VersionInfo.Productversion
            $driverVersion = $driverVersion.Substring(0, $driverVersion.LastIndexOf("."));
        }

        if ($chromeversion -ne $driverVersion) {
            $this.WriteHttpLog('Downloading driver...')
            $r = Invoke-RestMethod -Uri 'https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json'
            $dlurl = $null
            foreach ($ver in ($r.versions)) {
                [string]$v = $ver.version
                $v = $v.Substring(0, $v.LastIndexOf("."));
                if ($v -eq $chromeversion) {
                    foreach ($c in $ver.downloads.chromedriver) {
                        if ($c.platform -eq 'win64') {
                            $dlurl = $c.url
                        }
                    }
                }
            }

            $zipfilepath = "$PSScriptRoot/lib/"
            $zipfilename = 'chromedriver.zip'
            Invoke-WebRequest -Uri $dlurl -Method Get -OutFile "$zipfilepath$zipfilename"
            Expand-Archive -Path "$zipfilepath$zipfilename" -DestinationPath $zipfilepath -Force
            Remove-Item "$zipfilepath$zipfilename"
        }
        
        $this.WriteHttpLog('Launching browser for user to logon...')
        $uri = $this.omadaHttpConfig.httpConfig.webprotocol + $this.omadaHttpConfig.httpConfig.webhost
        
        $chrmdbgport = '9222'
        if ($null -ne $this.omadaHttpConfig.httpConfig.InvokeBrowserInteractive.chromedebugport) {
            $chrmdbgport = $this.omadaHttpConfig.httpConfig.InvokeBrowserInteractive.chromedebugport
        }
        $chromeDriverDirPath = "$PSScriptRoot\lib\chromedriver-win64"
        
        & $chromepath --remote-debugging-port=$chrmdbgport --user-data-dir="$env:LOCALAPPDATA\ODataLoader"
        
        Add-Type -Path "$PSScriptRoot\lib\selenium\webdriver.dll"
        $chromeOpts = New-Object OpenQA.Selenium.Chrome.ChromeOptions
        $chromeOpts.debuggerAddress = "127.0.0.1:$chrmdbgport"
        $chromeDriver = New-Object openQA.selenium.chrome.chromeDriver($chromeDriverDirPath, $chromeOpts)
        $chromeDriver.Url = $uri

        do {
            Start-Sleep -Milliseconds 1000
            $this.WriteHttpLog('Waiting for logon to complete...')
        } until ($chromeDriver.url.startswith($uri))
        
        $cookie = $chromeDriver.Manage().Cookies.GetCookieNamed('oisauthtoken').Value
        $this.WriteHttpLog('Got cookie:' + $cookie)
        
        $chromeDriver.Close()
        $chromeDriver.Quit()
        
        return $cookie
    }

    [PSObject]InvokeOmadaWebMethod([string]$method, [string]$uri, [Object]$body, [string]$contentType) {
        $this.WriteHttpLog('start ' + $method + $this.omadaHttpConfig.httpConfig.authentication)

        $resp = $null
        switch ($this.omadaHttpConfig.httpConfig.authentication) {

            'OAuthAzureADClientCredentials' {
                $resp = $this.InvokeOAUTHClientCredentials($method, $uri, $body, $contentType)
            }

            'Integrated' {
                $resp = $this.InvokeIntegrated($method, $uri, $body, $contentType)                
            }

            'Cookie' {
                $resp = $this.InvokeCookie($method, $uri, $body, $contentType)
            }

            'InvokeBrowserInteractive' {
                $resp = $this.InvokeBrowserInteractive($method, $uri, $body, $contentType)
            }

            default {                
                throw 'Invalid or no http authentication type specified : "' + ($this.omadaHttpConfig.httpConfig.authentication) + '"'             
            }
        }

        $this.WriteHttpLog('Response: ' + $resp)
        Return $resp
    }

    [PSObject]InvokeOmadaRestMethod([string]$method, [string]$uri, [String]$body) {
        $retryCount = 0
        $ex = $null

        do {
            try {
                $r = $this.InvokeOmadaWebMethod($method, $uri, $body, 'application/json; charset=utf-8')
                $res = $null
                if ($r.Content.Length -gt 0) {
                    $res = ConvertFrom-Json -InputObject ($r.Content)
                }
                if ($retryCount -gt 0) {
                    #display message when operation succeeds after a retry
                    AddLog -msg 'Retry succeeded' -color Green
                }
                return $res        
            }
            catch {
                $ex = $_
                $sc = $ex.exception.StatusCode.value__
                
                if ($sc -in @(400, 404, 500)) {
                    $retryCount = 5
                }
                else {
                    $msg = $ex.ToString()
                    AddLog -msg ('Error during http operation: ' + $msg + "`nMethod: " + $method + "`nURI: " + $uri + "`nRetry count $retryCount") -color Red
                    AddLog -msg 'Retrying in 5 seconds...' -color Yellow
                    Start-Sleep -Seconds 5
                    $retryCount++
                }
            }
            $retryCount++
        } while ($retryCount -lt 5)
        throw $ex
    }
    
    [PSObject]ODataPOST([string]$objectname, [String]$bodyStr) {
        $uri = "/OData/DataObjects/$objectname"
        $resp = $this.InvokeOmadaRestMethod('Post', $uri, $bodyStr)
        return $resp
    }

    [PSObject]ODataPOST([string]$objectname, [Hashtable]$body) {
        $bodyStr = ConvertTo-Json -Depth 10 $body
        return $this.ODataPOST($objectname, $bodyStr)
    }

    [PSObject]ODataGET([String]$objectname, [String]$params) {
        $uri = "/OData/DataObjects/$objectname$params"
        $resp = $this.InvokeOmadaRestMethod('Get', $uri, $null)
        return $resp
    }

    [PSObject]ODataPUT([int]$id, [string]$objectname, [Hashtable]$body) {
        $bodyStr = ConvertTo-Json -Depth 10 $body
        $uri = "/OData/DataObjects/$objectname($id)"
        $resp = $this.InvokeOmadaRestMethod('Put', $uri, $bodyStr)
        return $resp
    }

    ODataDELETE([string]$objectname, [int]$id) {
        $uri = "/OData/DataObjects/$objectname($id)"
        $null = $this.InvokeOmadaRestMethod('Delete', $uri, $null)    
    }

    [String]UrlEncode([String]$s) {
        #hack to allow use of external class without compiler complaining
        $expr = 'return [System.Web.HttpUtility]::UrlEncode(' + "'" + $s + "'" + ')'
        return Invoke-Expression ($expr)
    }    

} #class OmadaHttp


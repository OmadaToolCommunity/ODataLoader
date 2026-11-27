###################################################################################
# ODataLoader - control script
#
# Copyright (c) 2023 Omada A/S
#
# This tool is provided as-is without warranty of any kind, express or implied
# 
# Author: RLA
#
###################################################################################

clear-host

$httpcfg = @{
    timeoutSec                    = 6000
    webprotocol                   = 'https://'
    webhost                       = 'mytenant.omada.cloud'
    httpDetailedLogging           = 0
    authentication                = 'InvokeBrowserInteractive'
    
    OAuthAzureADClientCredentials = @{
        oauthTenantId         = "1c422168-1555-4089-9a66-27c0df6e614b"        
        oauthClientId         = "eee0f53e-95a8-4813-a80f-46ac2bad875c"
        oauthScope            = "api://93283f60-8bf9-4928-9218-ccc1d61d27af/.default"
        useLegacyBrowser      = $false
        oauthClientSecretFile = 'oauthsecret.txt'
    }

    InvokeBrowserInteractive      = @{
        chromedebugport = 9222
    }

    Cookie                        = @{
        Cookie = '01kZUGDRiESVMbHMtZ2miw=='
    }
}

./ODataLoader.ps1 -configfile './examples/Example-Role delta.json' -httpConfig $httpcfg

Set-Location $PSScriptRoot
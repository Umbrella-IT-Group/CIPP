# Pester tests for the request shaping in Invoke-ExecDeviceAction.
# The Graph call itself lives in New-CIPPDeviceAction; these check the body each action hands it.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

    class HttpResponseContext {
        [int]$StatusCode
        [object]$Body
    }

    function New-CIPPDeviceAction { param($Action, $ActionBody, $DeviceFilter, $TenantFilter, $Headers, $APINAME) }
    function New-GraphGetRequest { param($uri, $tenantid) }
    function Get-CIPPTextReplacement { param($TenantFilter, $Text) $Text }

    $EndpointPath = Join-Path $RepoRoot 'Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Endpoint/MEM/Invoke-ExecDeviceAction.ps1'
    $EndpointScript = [ScriptBlock]::Create("using namespace System.Net`n" + (Get-Content -LiteralPath $EndpointPath -Raw))
    . $EndpointScript

    function New-DeviceActionRequest {
        param([hashtable]$Body)
        $Merged = @{ tenantFilter = 'contoso.com'; GUID = 'device-guid' }
        foreach ($Key in $Body.Keys) { $Merged[$Key] = $Body[$Key] }
        [pscustomobject]@{
            Params  = @{ CIPPEndpoint = 'ExecDeviceAction' }
            Headers = @{}
            Body    = [pscustomobject]$Merged
        }
    }
}

Describe 'Invoke-ExecDeviceAction - on-demand remediation' {
    BeforeEach {
        Mock -CommandName New-CIPPDeviceAction -MockWith { 'Queued initiateOnDemandProactiveRemediation on device-guid' }
    }

    It 'sends only the selected script id as the Graph body' {
        $Request = New-DeviceActionRequest -Body @{
            Action         = 'initiateOnDemandProactiveRemediation'
            scriptPolicyId = [pscustomobject]@{ label = 'Clear Teams cache'; value = 'script-guid' }
        }

        $Response = Invoke-ExecDeviceAction -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be 200
        Should -Invoke New-CIPPDeviceAction -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'initiateOnDemandProactiveRemediation' -and
            $DeviceFilter -eq 'device-guid' -and
            $ActionBody -eq '{"scriptPolicyId":"script-guid"}'
        }
    }

    It 'accepts a bare script id' {
        $Request = New-DeviceActionRequest -Body @{
            Action         = 'initiateOnDemandProactiveRemediation'
            scriptPolicyId = 'script-guid'
        }

        $null = Invoke-ExecDeviceAction -Request $Request -TriggerMetadata $null

        Should -Invoke New-CIPPDeviceAction -Times 1 -Exactly -ParameterFilter { $ActionBody -eq '{"scriptPolicyId":"script-guid"}' }
    }

    It 'refuses to queue a run without a script' {
        $Request = New-DeviceActionRequest -Body @{ Action = 'initiateOnDemandProactiveRemediation' }

        $Response = Invoke-ExecDeviceAction -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be 500
        $Response.Body.Results | Should -Be 'Select a remediation script to run.'
        Should -Invoke New-CIPPDeviceAction -Times 0 -Exactly
    }
}

Describe 'Invoke-ExecDeviceAction - remove primary user' {
    BeforeEach {
        Mock -CommandName New-CIPPDeviceAction -MockWith { 'Removed primary user from device device-guid' }
    }

    It 'hands New-CIPPDeviceAction no body, not the serialized request body' {
        $Request = New-DeviceActionRequest -Body @{ Action = 'removePrimaryUser' }

        $Response = Invoke-ExecDeviceAction -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be 200
        $Response.Body.Results | Should -Be 'Removed primary user from device device-guid'
        Should -Invoke New-CIPPDeviceAction -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'removePrimaryUser' -and
            $DeviceFilter -eq 'device-guid' -and
            $TenantFilter -eq 'contoso.com' -and
            $null -eq $ActionBody
        }
    }

    It 'does not forward a user value that arrives in the request body' {
        $Request = New-DeviceActionRequest -Body @{
            Action = 'removePrimaryUser'
            user   = [pscustomobject]@{ label = 'Tech Account'; value = 'user-guid' }
        }

        $null = Invoke-ExecDeviceAction -Request $Request -TriggerMetadata $null

        Should -Invoke New-CIPPDeviceAction -Times 1 -Exactly -ParameterFilter { $null -eq $ActionBody }
    }

    It 'reports a failed removal as a 500 with the helper message' {
        Mock -CommandName New-CIPPDeviceAction -MockWith { throw 'Failed to queue action removePrimaryUser on device-guid : Resource not found' }
        $Request = New-DeviceActionRequest -Body @{ Action = 'removePrimaryUser' }

        $Response = Invoke-ExecDeviceAction -Request $Request -TriggerMetadata $null

        $Response.StatusCode | Should -Be 500
        $Response.Body.Results | Should -Be 'Failed to queue action removePrimaryUser on device-guid : Resource not found'
    }
}

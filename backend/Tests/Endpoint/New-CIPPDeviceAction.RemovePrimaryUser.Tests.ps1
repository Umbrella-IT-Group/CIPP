# Pester tests for the removePrimaryUser branch of New-CIPPDeviceAction.
#
# Pins the Graph contract proven against live Intune tenants: DELETE on
# managedDevices('{id}')/users/$ref with no request body and no user id in the path.
# The other actions are covered by the endpoint tests; this file only guards the new branch.

BeforeAll {
    # Resolve by name under Modules/ so the test survives the function moving between modules.
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter 'New-CIPPDeviceAction.ps1' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $FunctionPath) { throw 'Could not locate New-CIPPDeviceAction.ps1 under Modules/' }

    # Stub every CIPP helper the function calls so Pester's Mock has a command to replace.
    # New-GraphPOSTRequest is a recording stub rather than a Mock: $PSBoundParameters is empty
    # inside a Pester mock body, and "no body" has to mean the parameter was never bound.
    function New-GraphPOSTRequest {
        param($uri, $tenantid, $body, $type)
        $script:GraphCalls += , @{ Bound = @($PSBoundParameters.Keys); Uri = $uri; Type = $type; Tenant = $tenantid }
        if ($script:GraphError) { throw $script:GraphError }
    }
    function Invoke-CIPPMDEOffboard { param($AzureADDeviceId, $TenantFilter) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $Sev, $LogData) }
    function Get-CippException { param($Exception) [pscustomobject]@{ NormalizedError = "$($Exception.Exception.Message)" } }

    . $FunctionPath
}

Describe 'New-CIPPDeviceAction - removePrimaryUser' {
    BeforeEach {
        $script:GraphCalls = @()
        $script:GraphError = $null
        Mock -CommandName Write-LogMessage -MockWith { }
    }

    It 'sends a bodiless DELETE to users/$ref on the managed device' {
        $Result = New-CIPPDeviceAction -Action 'removePrimaryUser' -DeviceFilter 'dev-1' -TenantFilter 'contoso.com' -Headers @{} -APIName 'ExecDeviceAction'

        $Result | Should -Be 'Removed primary user from device dev-1'
        $script:GraphCalls.Count | Should -Be 1
        $Call = $script:GraphCalls[0]
        $Call.Uri | Should -BeExactly 'https://graph.microsoft.com/beta/deviceManagement/managedDevices(''dev-1'')/users/$ref'
        $Call.Type | Should -Be 'DELETE'
        $Call.Tenant | Should -Be 'contoso.com'
        # An explicit -body $null would also read as null, so check the parameter was never bound.
        $Call.Bound | Should -Not -Contain 'body'
    }

    It 'ignores an ActionBody handed in alongside the action' {
        $null = New-CIPPDeviceAction -Action 'removePrimaryUser' -ActionBody '{"user":"user-guid"}' -DeviceFilter 'dev-1' -TenantFilter 'contoso.com' -Headers @{} -APIName 'ExecDeviceAction'

        $script:GraphCalls.Count | Should -Be 1
        $script:GraphCalls[0].Bound | Should -Not -Contain 'body'
    }

    It 'logs the removal at Info against the tenant' {
        $null = New-CIPPDeviceAction -Action 'removePrimaryUser' -DeviceFilter 'dev-1' -TenantFilter 'contoso.com' -Headers @{} -APIName 'ExecDeviceAction'

        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter {
            $message -eq 'Removed primary user from device dev-1' -and
            $Sev -eq 'Info' -and
            $tenant -eq 'contoso.com' -and
            $API -eq 'ExecDeviceAction'
        }
    }

    It 'logs at Error and throws when Graph refuses the call' {
        $script:GraphError = 'Resource not found'

        { New-CIPPDeviceAction -Action 'removePrimaryUser' -DeviceFilter 'dev-1' -TenantFilter 'contoso.com' -Headers @{} -APIName 'ExecDeviceAction' } |
            Should -Throw -ExpectedMessage 'Failed to queue action removePrimaryUser on dev-1 : Resource not found'

        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter { $Sev -eq 'Error' }
    }
}

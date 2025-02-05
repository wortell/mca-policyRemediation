param(
    [Parameter(Mandatory = $true)]
    [string]$rootManagementGroup,
    [Parameter(Mandatory = $true)]
    [string]$managementManagementGroup,
    [Parameter(Mandatory = $true)]
    [string]$connectivityManagementGroup,
    [Parameter(Mandatory = $true)]
    [string]$identityManagementGroup,
    [Parameter(Mandatory = $true)]
    [string]$landingZoneManagementGroup,
    [string]$azureEnvironmentURI = "management.azure.com"
)

# Define the policies to remediate and the appropriate management groups to remediate them in
$policies = @( 
    [PSCustomObject]@{
        policyName      = "Alerting-Management"
        managementGroup = $managementManagementGroup
    },
    [PSCustomObject]@{
        policyName      = "Alerting-Connectivity"
        managementGroup = $connectivityManagementGroup
    },
    [PSCustomObject]@{
        policyName      = "Alerting-Identity"
        managementGroup = $identityManagementGroup
    },
    [PSCustomObject]@{
        policyName      = "Alerting-LandingZone"
        managementGroup = $landingZoneManagementGroup
    },
    [PSCustomObject]@{
        policyName      = "Alerting-ServiceHealth"
        managementGroup = $rootManagementGroup
    },
    [PSCustomObject]@{
        policyName      = "Notification-Assets"
        managementGroup = $rootManagementGroup
    },
    [PSCustomObject]@{
        policyName      = "Alerting-HybridVM"
        managementGroup = $rootManagementGroup
    }
)

# Function to trigger remediation for a single policy
Function Start-PolicyRemediation {
    Param(
        [Parameter(Mandatory = $true)] [string] $azureEnvironmentURI,
        [Parameter(Mandatory = $true)] [string] $managementGroupName,
        [Parameter(Mandatory = $true)] [string] $policyAssignmentName,
        [Parameter(Mandatory = $true)] [string] $policyAssignmentId,
        [Parameter(Mandatory = $false)] [string] $policyDefinitionReferenceId
    )
    $guid = New-Guid
    # Create remediation for the individual policy
    $uri = "https://$($azureEnvironmentURI)/providers/Microsoft.Management/managementGroups/$($managementGroupName)/providers/Microsoft.PolicyInsights/remediations/$($policyAssignmentName)-$($guid)?api-version=2021-10-01"
    $body = @{
        properties = @{
            policyAssignmentId = "$policyAssignmentId"
        }
    }
    if ($policyDefinitionReferenceId) {
        $body.properties.policyDefinitionReferenceId = $policyDefinitionReferenceId
    }
    $body = $body | ConvertTo-Json -Depth 10
    Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $body
}

# Function to get the policy assignments in the management group scope
function Get-PolicyType {
    Param (
        [Parameter(Mandatory = $true)] [string] $azureEnvironmentURI,
        [Parameter(Mandatory = $true)] [string] $managementGroupName,
        [Parameter(Mandatory = $true)] [string] $policyName
    )

    # Validate that the management group exists through the Azure REST API
    $uri = "https://$($azureEnvironmentURI)/providers/Microsoft.Management/managementGroups/$($managementGroupName)?api-version=2021-04-01"
    $result = (Invoke-AzRestMethod -Uri $uri -Method GET).Content | ConvertFrom-Json -Depth 100
    if ($result.error) {
        throw "Management group $managementGroupName does not exist, please specify a valid management group name"
    }

    # Get custom policy set definitions
    $uri = "https://$($azureEnvironmentURI)/providers/Microsoft.Management/managementGroups/$($managementGroupName)/providers/Microsoft.Authorization/policySetDefinitions?&api-version=2023-04-01"
    $initiatives = (Invoke-AzRestMethod -Uri $uri -Method GET).Content | ConvertFrom-Json -Depth 100

    # Get policy assignments within the management group
    $assignmentFound = $false
    $uri = "https://$($azureEnvironmentURI)/providers/Microsoft.Management/managementGroups/$($managementGroupName)/providers/Microsoft.Authorization/policyAssignments?`$filter=atScope()&api-version=2022-06-01"
    $result = (Invoke-AzRestMethod -Uri $uri -Method GET).Content | ConvertFrom-Json -Depth 100

    # Iterate through the policy assignments
    $result.value | ForEach-Object {
        # Check if the policy assignment matches the specified policy name
        If ($($PSItem.properties.policyDefinitionId) -match "/providers/Microsoft.Authorization/policySetDefinitions/$policyName") {
            # Go to enumerating the policy set
            $assignmentFound = $true
            Enumerate-PolicySet -azureEnvironmentURI $azureEnvironmentURI -managementGroupName $managementGroupName -policyAssignmentObject $PSItem
        }
        Elseif ($($PSItem.properties.policyDefinitionId) -match "/providers/Microsoft.Authorization/policyDefinitions/$policyName") {
            # Go to handling individual policy
            $assignmentFound = $true
            Enumerate-Policy -azureEnvironmentURI $azureEnvironmentURI -managementGroupName $managementGroupName -policyAssignmentObject $PSItem
        }
    }

    # If no policy assignments were found for the specified policy name, throw an error
    If (!$assignmentFound) {
        throw "No policy assignments found for policy $policyName at management group scope $managementGroupName"
    }
}

# Function to enumerate the policies in the policy set and trigger remediation for each individual policy
function Enumerate-PolicySet {
    param (
        [Parameter(Mandatory = $true)] [string] $azureEnvironmentURI,
        [Parameter(Mandatory = $true)] [string] $managementGroupName,
        [Parameter(Mandatory = $true)] [object] $policyAssignmentObject
    )

    # Extract policy assignment information
    $policyAssignmentObject
    $policyAssignmentId = $policyAssignmentObject.id
    $name = $policyAssignmentObject.name
    $policySetId = $policyAssignmentObject.properties.policyDefinitionId
    $policySetId
    $psetUri = "https://$($azureEnvironmentURI)$($policySetId)?api-version=2021-06-01"
    $policySet = (Invoke-AzRestMethod -Uri $psetUri -Method GET).Content | ConvertFrom-Json -Depth 100
    $policySet
    $policies = $policySet.properties.policyDefinitions

    # Iterate through the policies in the policy set
    If ($policyAssignmentObject.properties.policyDefinitionId -match "/providers/Microsoft.Authorization/policySetDefinitions/Alerting-ServiceHealth") {
        $policyDefinitionReferenceId = "Deploy_ServiceHealth_ActionGroups"
        Start-PolicyRemediation -azureEnvironmentURI $azureEnvironmentURI -managementGroupName $managementGroupName -policyAssignmentName $name -policyAssignmentId $policyAssignmentId -policyDefinitionReferenceId $policyDefinitionReferenceId
        Write-Host " Waiting for 5 minutes while remediating the 'Deploy Service Health Action Group' policy before continuing." -ForegroundColor Cyan
        Start-Sleep -Seconds 360
    }
    Foreach ($policy in $policies) {
        $policyDefinitionId = $policy.policyDefinitionId
        $policyDefinitionReferenceId = $policy.policyDefinitionReferenceId

        # Trigger remediation for the individual policy
        Start-PolicyRemediation -azureEnvironmentURI $azureEnvironmentURI -managementGroupName $managementGroupName -policyAssignmentName $name -policyAssignmentId $policyAssignmentId -policyDefinitionReferenceId $policyDefinitionReferenceId
    }
}

# Function to get specific information about a policy assignment for a single policy and trigger remediation
function Enumerate-Policy {
    param (
        [Parameter(Mandatory = $true)] [string] $azureEnvironmentURI,
        [Parameter(Mandatory = $true)] [string] $managementGroupName,
        [Parameter(Mandatory = $true)] [object] $policyAssignmentObject
    )
    # Extract policy assignment information
    $policyAssignmentId = $policyAssignmentObject.id
    $name = $policyAssignmentObject.name
    $policyDefinitionId = $policyAssignmentObject.properties.policyDefinitionId
    Start-PolicyRemediation -azureEnvironmentURI $azureEnvironmentURI -managementGroupName $managementGroupName -policyAssignmentName $name -policyAssignmentId $policyAssignmentId
}

# Connect to Azure
Connect-AzAccount -Identity

# Run policy remediation
$problemsOccurred = $false
foreach ($object in $policies) {
    $policy = $object.policyName
    $managementGroupName = $object.managementGroup

    Write-Host "Processing policy: $policy" -ForegroundColor Cyan
    try {
        Get-PolicyType -azureEnvironmentURI $azureEnvironmentURI -managementGroupName $managementGroupName -policyName $policy
    } catch {
        write-error "Policy $policy not found.`n$_"
        $problemsOccurred = $true
        continue
    }
}

if ($problemsOccurred) {
    "One or more policies failed to remediate"
    throw
}
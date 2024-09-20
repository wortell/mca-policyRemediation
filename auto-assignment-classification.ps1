[cmdletbinding()]
param(
    [Parameter(Mandatory = $true)]
    $rootManagementGroup
)

$policies = @('McaClassificationTagGold', 'McaClassificationTagSilver', 'McaClassificationTagBronze', 'McaClassificationTagInformational')

#region connect to Azure
try {
    Connect-AzAccount -Identity
}
catch {
    Write-Error "Unable to connect to Azure.`n$_"
    exit 1
}
#endregion

#region create a variable to make sure no errors have occurred during the run.
$problemsOccurred = $false
#endregion

$params = @{
    managementGroupName = $rootManagementGroup
}

#region loading functions
function New-PolicyAssignmentMgSubscription {
     <#
    .SYNOPSIS
    This function assigns a policy to all subscriptions in a management group or a specific subscription.
    
    .DESCRIPTION
    This function assigns a policy to all subscriptions in a management group or a specific subscription.
    If the parameter set 'ManagementGroup' is used, the function will get all subscriptions in the management group and underlying management groups and assign the policy to all of them.
    The policy assignment name will be the policy name followed by the subscription name.
    
    .PARAMETER managementGroupName
    The name of the management group to get subscriptions from.
    
    .PARAMETER policyName
    The name of the policy to assign.
    
    .PARAMETER location
    The location for the System Assigned Managed Identity in case of remediation.
    
    .PARAMETER subscriptionId
    The subscription ID to assign the policy to. This parameter is only used when the parameter set 'Subscription' is used.
    In this case the function will only assign the policy to the specified subscription.
    
    .EXAMPLE
    New-PolicyAssignmentMgSubscription -managementGroupName 'PSP-Subscriptions' -policyName 'McaClassificationTagGold'

    This example assigns the policy 'McaClassificationTagGold' to all subscriptions in the management group 'PSP-Subscriptions'.
    
    .NOTES
    Author         : Robert Prüst
    #>
    [cmdletbinding(DefaultParameterSetName = 'ManagementGroup')]
    param(
        [Parameter(Mandatory = $true , ParameterSetName = 'ManagementGroup', Position = 0, HelpMessage = 'Name of the management group to get subscriptions from.')]
        [Parameter(Mandatory = $true , ParameterSetName = 'Subscription', Position = 0, HelpMessage = 'Name of the management group to get subscriptions from.')]
        [string]$managementGroupName,

        [Parameter(Mandatory = $true, ParameterSetName = 'ManagementGroup', Position = 1, HelpMessage = 'Name of the policy to assign.')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Subscription', Position = 1, HelpMessage = 'Name of the policy to assign.')]
        [string]$policyName,

        [Parameter(Mandatory = $false, ParameterSetName = 'ManagementGroup', Position = 2, HelpMessage = 'Location for the Managed Identity.')]
        [Parameter(Mandatory = $false, ParameterSetName = 'Subscription', Position = 2, HelpMessage = 'Location for the Managed Identity.')]
        [string]$location = 'westeurope',

        [Parameter(Mandatory = $true, ParameterSetName = 'Subscription', Position = 3, HelpMessage = 'Subscription ID to assign the policy to.')]
        [string]$subscriptionId
    )
    begin {
        # Function to get all subscriptions in a management group
        function Get-AllMgSubscriptions {
            <#
            .SYNOPSIS
            This function gets all subscriptions in a management group and underlying management groups.
            
            .DESCRIPTION
            This function gets all subscriptions in a management group and underlying management groups.
            
            .PARAMETER ManagementGroupName
            The name of the management group to get subscriptions from.
            
            .EXAMPLE
            Get-AllMgSubscriptions -ManagementGroupName 'PSP-Subscriptions'

            This example gets all subscriptions in the management group 'PSP-Subscriptions' and underlying management groups.
            
            .NOTES
            Author         : Robert Prüst
            #>
            [cmdletbinding()]
            param (
                [Parameter(Mandatory = $true, HelpMessage = 'Management Group Name to query for subscriptions.')]
                [string]$ManagementGroupName
            )
    
            try {
                $rootManagementGroup = Get-AzManagementGroup -GroupName $managementGroupName -Expand -Recurse -ErrorAction Stop
            }
            catch {
                Write-Error "Failed to get management group info for '$managementGroupName'.`n$($_.Exception.Message)"
                throw
            }
    
            # Create a collection to store all information in 
            $subscriptionInfo = [System.Collections.Generic.List[pscustomobject]]::new()
    
            # Create a variable to store the level of the subscription in the management group hierarchy
            $level = 0
    
            # Get the home tenant id
            $homeTenantId = $rootManagementGroup.TenantId
    
            # Loop through the subscriptions in the root management group
            foreach ($subscription in $rootManagementGroup.Children.where({ $_.Type -match 'subscriptions' })) {
                $info = [pscustomobject]@{
                    SubscriptionName  = $subscription.DisplayName
                    SubscriptionId    = $subscription.Name
                    ParentMg          = $rootManagementGroup.DisplayName
                    TenantId          = $homeTenantId
                    SubscriptionLevel = $level
                }
                $subscriptionInfo.Add($info)
            }
    
            # Loop through the management groups in the root management group, untill there are no more management groups
            while ($rootManagementGroup.Children.where({ $_.Type -match 'managementGroups' }).Count -gt 0) {
                $level++
                foreach ($managementGroup in $rootManagementGroup.Children.where({ $_.Type -match 'managementGroups' })) {
                    foreach ($subscription in $managementGroup.Children.where({ $_.Type -match 'subscriptions' })) {
                        $info = [pscustomobject]@{
                            SubscriptionName  = $subscription.DisplayName
                            SubscriptionId    = $subscription.Name
                            ParentMg          = $managementGroup.DisplayName
                            TenantId          = $homeTenantId
                            SubscriptionLevel = $level
                        }
                        $subscriptionInfo.Add($info)
                    }
                }
                $rootManagementGroup = $rootManagementGroup.Children.where({ $_.Type -match 'managementGroups' })
            }
    
            # Output the information
            $subscriptionInfo
        }

        # Check the parameter set used 
        if ($PSCmdlet.ParameterSetName -eq 'Subscription') {
            Write-Verbose "Subscription set - Getting subscription with ID '$subscriptionId'"
            # Getting the policy definition
            try {
                $subscriptionInfo = Get-AzSubscription -SubscriptionId $subscriptionId -ErrorAction Stop
                $subscriptions = [pscustomobject]@{
                    SubscriptionId   = $subscriptionInfo.Id
                    SubscriptionName = $subscriptionInfo.Name
                }
            }
            catch {
                Write-Error "Failed to get subscription with ID '$subscriptionId': $_"
                exit 1
            }
        } 

        if ($PSCmdlet.ParameterSetName -eq 'ManagementGroup') {
            Write-Verbose "Management Group set - Getting subscriptions in management group '$managementGroupName'"
            # Getting all subscriptions in a management group
            try {
                $subscriptions = Get-AllMgSubscriptions -ManagementGroupName $managementGroupName -ErrorAction Stop
            }
            catch {
                Write-Error "Failed to get subscriptions in management group '$managementGroupName': $_"
                exit 1
            }
        }


        # Getting the policy definition
        try {
            $policy = Get-AzPolicyDefinition -Name $policyName -ManagementGroupName $managementGroupName -ErrorAction Stop
        }
        catch {
            Write-Error "Failed to get policy definition '$policyName' in management group '$managementGroupName': $_"
            exit 1
        }

        # setting the assignment parameters
        $assignmentParams = @{
            PolicyDefinition = $policy
            IdentityType     = 'SystemAssigned'
            Location         = $location # 
            ErrorAction      = 'Stop'
        }
    }
    process {
        # Assigning the policy to all subscriptions
        foreach ($subscription in $subscriptions) {
            Write-Verbose "Assigning policy '$policyName' to subscription '$($subscription.SubscriptionName)'"
            $assignmentName = "{0}-{1}" -f $policyName, $subscription.SubscriptionName
            if ($assignmentName.Length -gt 64) {
                $assignmentName = $assignmentName.Substring(0, 64)
            }
            $assignmentParams.Name = $assignmentName
            $assignmentParams.Scope = "/subscriptions/$($subscription.SubscriptionId)"

            try {
                New-AzPolicyAssignment @assignmentParams
            }
            catch {
                Write-Error "Failed to assign policy '$policyName' to subscription '$($subscription.SubscriptionName)': $_"
                $problemsOccurred = $true
                continue # Continue with the next subscription even if one fails
            }
        }

    } 
    end {
        if ($problemsOccurred) {
            "One or more policies failed to assign"
            throw
        }
    }
}
#endregion

foreach ($policy in $policies) {
    $params.policyName = $policy
    New-PolicyAssignmentMgSubscription @params
}

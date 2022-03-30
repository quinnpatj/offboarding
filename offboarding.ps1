
<# Offboarding Script - Patrick Quinn, 2021

==================================================== ABOUT: ===================================================

   Script to automate user account offboarding for service desk technicians:
   1. Disables AD account, resets password, and removes all groups
   2. Blocks O365 account and forces sign out, removes licenses and converts to shared mailbox
   3. Backs up user's groups and distribution lists to Documents and reassigns OneDrive access

   This script requries the AzureAD, ExchangeOnline, and SharepointOnline modules

===============================================================================================================
#>

#  Functions for script:

function Get-SignIn {

    #  Sets credentials for use throughout script

    $admin = $env:USERDNSDOMAIN + "\" + $env:USERNAME
    $script:Cred = Get-Credential $admin -Message "Enter your AD admin credentials:"

   #  Connects to SharePoint Online for OneDrive admin:

   $tenant = $env:USERDOMAIN
   Connect-SPOService -Url https://$tenant-admin.sharepoint.com
}

function Connect-OnPrem {

    #  Connects to OnPrem Exchange:

    Write-Host
    Write-Host "Connecting to OnPrem Exchange..."

    $fqdn = Read-Host "What is the FQDN of the Exchange server?"
    $uri = "http://" + $fqdn + "/PowerShell/"
    $script:Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri $uri -Authentication Kerberos -Credential $Cred

    Import-PSSession $Session -DisableNameChecking -AllowClobber | Out-Null
}

function Connect-O365 {

    #  Connects to O365 Exchange with MFA:

    $UPN = (Get-ADUser $env:USERNAME -Properties UserPrincipalName).UserPrincipalName #Read-Host "Enter your Email Address for MFA verification"

    Write-Host
    Write-Host "Connecting to O365 Exchange..."
	
    Connect-ExchangeOnline -UserPrincipalName $UPN | Out-Null
    
    #  Connects to Azure AD:

    Connect-AzureAD -AccountId $UPN | Out-Null
}


#  Gets AD admin credentials:

Get-SignIn


#  Starts offboarding loop:

Do {

    #  Connect to OnPrem Exchange and choose user to be offboarded
  
    Connect-OnPrem

    Write-Host
    $userName = Read-Host "What is the username to be offboarded?"
    $Name = (Get-ADUser $userName -Properties Name).Name
    $Email = (Get-ADUser $userName -Properties UserPrincipalName).UserPrincipalName
    $OU = (Get-ADUser $userName -Server $env:USERDOMAIN -Properties distinguishedName).distinguishedName
    $manager = (Get-ADUser $userName -Server $env:USERDOMAIN -Properties Manager).Manager
    
    try {
        $manEmail = (Get-ADUser $manager -Properties UserPrincipalName).UserPrincipalName
    }
    catch {
    }

    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $DOR = $date

    Write-Host
    Write-Host "Verify User To Be Offboarded:" -BackgroundColor Yellow -ForegroundColor DarkBlue
    [pscustomobject]@{
        Name =  ($Name -join ', ');
        SamAccountName =  ($userName -join ', ');
        UserPrincipalName = ($Email -join ', ');
        DistinguishedName = ($OU -join ', ');
        Manager = ($manEmail -join ', ');
        DateOfRelease = ($DOR -join ', ');
    }

    $verify = Read-Host "Is the above the correct user to be offboarded? [y / n]"

    if ($verify -eq "y" -or $verify -eq "Y") {

        Write-Host
        Write-Host "Beginning offboarding for user $userName" -BackgroundColor Yellow -ForegroundColor DarkBlue

        # Disables AD account

        Write-Host
        Write-Host "Disabling $env:USERDOMAIN AD account..." -BackgroundColor White -ForegroundColor DarkBlue

        Disable-ADAccount $userName -Server $env:USERDOMAIN -Credential $Cred


        #  Resets user's password

        Add-Type -Assembly System.Web
        $NewPassword = [Web.Security.Membership]:: GeneratePassword(12,3)
        Set-ADAccountPassword -Identity $userName -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $NewPassword -Force) -Server $env:LOGONSERVER -Credential $Cred
        #Get-ADUser -Identity $userName | Set-ADUser -ChangePasswordAtLogon:$true -Credential $Cred


        #  Updates AD attributes, removes from groups, and moves to Disabled OU

        Set-ADUser -Server $env:USERDOMAIN $userName -Clear physicalDeliveryOfficeName, company, manager -Credential $Cred
        Set-ADUser -Server $env:USERDOMAIN $userName -Clear info -Credential $Cred
        Set-ADUser -Server $env:USERDOMAIN $userName -Add @{
            info = "Date of Release: $DOR"
        } -Credential $Cred

        Set-ADUser $userName -Replace @{
            msExchHideFromAddressLists = $True
        } -Credential $Cred

        $path = $env:USERPROFILE + "\Documents\Offboarding_Backups"

        If (!(Test-Path $path)) {
        
            New-Item -ItemType Directory -Force -Path $path
        }

        $Groups = (Get-ADUser -Identity $userName -Properties memberOf).memberOf

        $Groups | Out-File -FilePath $path\"$userName"_SGs_Backup.txt -append

        ForEach ($Group In $Groups) {
        
            Remove-ADGroupMember -Identity $Group -Members $userName -Credential $Cred -Confirm:$false
        }

        $targetOU = "OU=Disabled,OU=Accounts,DC=" + $env:USERDOMAIN + ",DC=net"
        Move-ADObject -Identity $OU -TargetPath $targetOU -Server $env:USERDOMAIN -Credential $Cred

        Remove-PSSession $Session


        #  Disables secondary domain account

        $domain2 = Read-Host "What is the secondary domain name?"
        Write-Host
        Write-Host "Disabling $domain2 AD account..." -BackgroundColor White -ForegroundColor DarkBlue

        try {
            $OU2 = (Get-ADUser $userName -Server $domain2 -Properties distinguishedName).distinguishedName
            Disable-ADAccount $userName -Server $domain2 -Credential $Cred
            Set-ADUser -Server $domain2 $userName -Clear physicalDeliveryOfficeName, company, manager -Credential $Cred
            Set-ADUser -Server $domain2 $userName -Clear info -Credential $Cred
            Set-ADUser -Server $domain2 $userName -Add @{
                info ="Date of Release: $DOR"
            } -Credential $Cred
            $targetOU2 = "OU=Disabled,OU=Accounts,DC=" + $domain2 + ",DC=net"
            Move-ADObject -Identity $OU2 -TargetPath $targetOU2 -Server $domain2 -Credential $Cred
        }
        catch {
            Write-Host
            Write-Host "No $domain2 account found for $userName" -BackgroundColor Yellow -ForegroundColor DarkBlue
        }

        #  Connects to O365 Exchange and removes the user from all DGs they are in

        Connect-O365

        Write-Host "Removing AD and O365 groups..." -BackgroundColor White -ForegroundColor DarkBlue

        $SourceMailbox = Get-EXOMailbox $Email
        $DN=$SourceMailbox.DistinguishedName
        $Filter = "Members -like ""$DN"""
        $DGs = Get-DistributionGroup -ResultSize Unlimited -Filter $Filter | Select-Object -Expand Name

        $DGs | Out-File -FilePath $path\"$userName"_DGs_Backup.txt -append

        Write-Host

        foreach( $dg in $DGs) {
        
            Remove-DistributionGroupMember $dg -Member $Email -Confirm:$false
            Write-Host "$Email removed from $dg"
        }


        #  Removes the user from all O365 groups they are in

        $UGs = Get-UnifiedGroup -ResultSize Unlimited -Filter $Filter | Select-Object -Expand Name

        $UGs | Out-File -FilePath $path\"$userName"_UGs_Backup.txt -append

        Write-Host

        foreach( $ug in $UGs) {
        
            Remove-UnifiedGroupLinks $ug -LinkType Owners -Links $Email -Confirm:$false
            Write-Host "$Email removed from $ug"
        }

        foreach( $ug in $UGs) {
        
            Remove-UnifiedGroupLinks $ug -LinkType Members -Links $Email -Confirm:$false
            Write-Host "$Email removed from $ug"
        }


        #  Converts mailbox to shared mailbox

        Write-Host
        Write-Host "Converting $Email to shared mailbox and removing licenses..." -BackgroundColor White -ForegroundColor DarkBlue

        Set-Mailbox $Email -Type Shared
        sleep -Seconds 30


        #  Blocks O365 sign-in and removes licenses

        Set-AzureADUser -ObjectId $Email -AccountEnabled $false

        $a = Get-AzureADUser -ObjectId $Email
        $skuids = $a.AssignedLicenses.skuid
        $License = New-Object -TypeName Microsoft.Open.AzureAD.Model.AssignedLicense
        $LicensesToAssign = New-Object -TypeName Microsoft.Open.AzureAD.Model.AssignedLicenses
        $LicensesToAssign.AddLicenses = @()
        foreach($skuid in $skuids){$License.SkuId = $skuid; $LicensesToAssign.RemoveLicenses = $License.SkuId; Set-AzureADUserLicense -ObjectId $Email -AssignedLicenses $LicensesToAssign}


        # Disables Outlook mobile app and OWA then wipes the account from mobile devices

        Write-Host
        Write-Host "Disabling ActiveSync and OWA..." -BackgroundColor White -ForegroundColor DarkBlue

        Set-CASMailbox -Identity $Email -ActiveSyncEnabled $false -OWAEnabled $false


        #  Forces O365 sign out

        Write-Host
        Write-Host "Forcing O365 sign-out..." -BackgroundColor White -ForegroundColor DarkBlue

        Revoke-AzureADUserAllRefreshToken -ObjectId $Email
        Get-AzureADUser -SearchString $Email| Revoke-AzureADSignedInUserAllRefreshToken


        #  Sets auto-reply message
    
        Write-Host
        Write-Host "Setting transition alert auto-reply message..." -BackgroundColor Yellow -ForegroundColor DarkBlue

        Write-Host
        $poc = Read-Host "Is $manEmail the correct point of contact for the auto-reply? [y / n]"

        if ($poc -eq "n" -or $poc -eq "N") {

            $manEmail = Read-Host "What email address should be referenced in the auto-reply?"
        }

        Set-MailboxAutoReplyConfiguration $Email -AutoReplyState Enabled -InternalMessage "<html><body>**Transition Alert**<br>This email is no longer being monitored as of $DOR.<br>For assistance during my absence, please reach out to $manEmail</body></html>" -ExternalAudience None -Confirm:$false

        Clear-Variable manager, manEmail

        Write-Host
        Disconnect-ExchangeOnline -Confirm:$false | Out-Null

        # Reassigns OneDrive access to members of ITOM_SN for file backup

        $tenant = "$env:USERDOMAIN"
        $upn = (Get-ADUser $userName -Properties UserPrincipalName).UserPrincipalName
        $logonName = $upn.Split("@")[0]
        $domain = $upn.Split("@")[1]
        $domain = $domain.Split(".")[0]
        $first = $logonName.Split(".")[0]
        $last = $logonName.Split(".")[1]
        $url = "$first"+"_"+"$last"+"_"+"$domain"+"_"+"com"
        $url2 = "https://$tenant-my.sharepoint.com/personal/$url"

        Write-Host
        $owners = Get-ADGroupMember "ITOM_SN"
        $owners | foreach {
            $newOwner = (Get-ADUser $_ -Properties UserPrincipalName).UserPrincipalName
            Set-SPOUser -Site $url2 -LoginName $newOwner -IsSiteCollectionAdmin $true -ErrorAction SilentlyContinue | Out-Null # Change to $false to remove access
            Write-Host "Granted OneDrive access to $newOwner"
        }

        Write-Host
        Write-Host "Files will be available at the following URL after 10-15 minutes: $url2"

        #  Prompts for loop restart

        Write-Host
        Write-Host "Offboarding for user $userName complete." -BackgroundColor Green -ForegroundColor White
    }

    else {

        Write-Host
        Write-Host "Offboarding for user $userName cancelled." -BackgroundColor Red -ForegroundColor White
    }

    Write-Host
    $continue = Read-Host "Do you want to offboard another user? [y / n]"
}

Until ($continue -eq "n" -or $continue -eq "N")

#  Connects to AD Sync server and forces a delta sync

Disconnect-SPOService

$syncServ = Read-Host "What is the AD sync server?"
Invoke-Command -ComputerName $syncServ -ScriptBlock {
    
    Import-Module ADSync
    Start-ADSyncSyncCycle -PolicyType Delta
} -Credential $Cred | Out-Null

Return
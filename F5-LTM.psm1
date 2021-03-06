<#
AUTHOR: Joel Newton
CREATED DATE: 5/13/15
LAST UPDATED DATE: 6/8/15

SYNOPSIS

This module uses the F5 LTM REST API to manipulate and query pools and pool members
It is built to work with version 11.6
	    
DEPENDENCIES

It depends on the TunableSSLValidator module authored by Jaykul (https://github.com/Jaykul/Tunable-SSL-Validator) to allow for using the REST API 
with LTM devices using self-signed SSL certificates. If you are not connecting to your LTM(s) via SSL or you're using a trusted 
certificate, then the TunableSSLValidator module is not needed and you can remove the -Insecure parameter from the Invoke-WebRequest calls

#>

Function Get-F5session{
# Generate an F5 session object to be used in querying and changing the F5 LTM
# This function takes the DNS name or IP address of the F5 LTM device, and a username for an account 
# with the privileges modify the LTM via the REST API, and the user's password as a secure string.
# To generate a secure string from plain text, use:
# $F5Password = ConvertTo-SecureString -String $Password -AsPlainText -Force  

    param(
        [Parameter(Mandatory=$true)][string]$LTMName,
        [Parameter(Mandatory=$true)][string]$F5UserName,
        [Parameter(Mandatory=$true)][Security.SecureString]$F5Password        
    )

    $BaseURL = "https://$LTMName/mgmt/tm/ltm/"

    #Create credential object for connecting to REST API
    $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $F5UserName, $F5Password

    [pscustomobject]@{BaseURL = $BaseURL; Credential = $Credential}
}

Function Get-F5Status{
#Test whether the specified F5 is currently in active or standby failover mode

    param (
        [Parameter(Mandatory=$true)]$F5session
    )

    $FailoverPage = $F5Session.BaseURL -replace "/ltm/", "/cm/failover-status"

    $FailoverJSON = Invoke-WebRequest -Insecure -Uri $FailoverPage -Credential $F5Session.Credential

    $FailOver = $FailoverJSON.Content | ConvertFrom-Json

    #This is where the failover status is indicated
    $FailOverStatus = $failover.entries.'https://localhost/mgmt/tm/cm/failover-status/0'.nestedStats.entries.status.description

    #Return the failover status value
    $FailOverStatus

}


Function Get-VirtualServerList{
#Get a list of all virtual servers for the specified F5 LTM
    
    param (
        [Parameter(Mandatory=$true)]$F5session
    )

    #Only retrieve the pool names
    $VirtualServersPage = $F5session.BaseURL + 'virtual?$select=name'

    $VirtualServersJSON = Invoke-WebRequest -Insecure -Uri $VirtualServersPage -Credential $F5session.Credential

    $VirtualServers = $VirtualServersJSON.Content | ConvertFrom-Json

    $VirtualServers.items.name

}



Function Get-VirtualServer{
#Retrieve the specified virtual server

    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$VirtualServerName
    )

    Write-Verbose "NB: Virtual server names are case-specific."

    #Build the URI for this virtual server
    $URI = $F5session.BaseURL + "virtual/$VirtualServerName"

    $VirtualServerJSON = Invoke-WebRequest -Insecure -Uri $URI -Credential $F5session.Credential -ErrorAction SilentlyContinue

    If ($VirtualServerJSON){
        $VirtualServer = $VirtualServerJSON.Content | ConvertFrom-Json
        $VirtualServer
    }
    Else {

        Write-Error ("The $VirtualServerName pool does not exist.")
    }

}

Function Test-VirtualServer {
#Test whether the specified virtual server exists
#NB: Pool names are case-specific.
    
    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$VirtualServerName
    )

    Write-Verbose "NB: Virtual server names are case-specific."

    #Build the URI for this virtual server
    $URI = $F5session.BaseURL + "virtual/$VirtualServerName"

    $VirtualServerJSON = Invoke-WebRequest -Insecure -Uri $URI -Credential $F5session.Credential -ErrorAction SilentlyContinue

    If ($VirtualServerJSON){
        $true
    }
    Else {
        $false
    }

}


Function New-VirtualServer{

    param (
        [Parameter(Mandatory=$true)]$F5session,
        $Kind="tm:ltm:virtual:virtualstate",
        [Parameter(Mandatory=$true)][string]$VirtualServerName,
        $Description,
        [Parameter(Mandatory=$true)]$DestinationIP,
        [Parameter(Mandatory=$true)]$DestinationPort,
        $Source='0.0.0.0/0',
        $DefaultPool,
        [string[]]$ProfileNames,
        [Parameter(Mandatory=$true,ParameterSetName = 'IpProtocol')]
        [ValidateSet("tcp","udp","sctp")]
        $ipProtocol,
        $Mask='255.255.255.255',
        $ConnectionLimit='0'
    )
    
    $URI = ($F5session.BaseURL + "virtual")

    #Check whether the specified virtual server already exists
    If (Test-VirtualServer -F5session $F5session -VirtualServerName $VirtualServerName){
        Write-Error "The $VirtualServerName pool already exists."
    }

    Else {

        #Start building the JSON for the action
        $Destination = $DestinationIP + ":" + $DestinationPort
        $JSONBody = @{kind=$Kind;name=$VirtualServerName;description=$Description;partition='Common';destination=$Destination;source=$Source;pool=$DefaultPool;ipProtocol=$ipProtocol;mask=$Mask;connectionLimit=$ConnectionLimit}

        #Build array of profile items
        #JN: What happens if a non-existent profile is passed in?
        $ProfileItems = @()
        ForEach ($ProfileName in $ProfileNames){
            $ProfileItems += @{kind='tm:ltm:virtual:profiles:profilesstate';name=$ProfileName}
        }
        $JSONBody.profiles = $ProfileItems

        $JSONBody = $JSONBody | ConvertTo-Json

        Write-Verbose $JSONBody

        $response = Invoke-WebRequest -Insecure -Method POST -Uri "$URI" -Credential $F5session.Credential -Body $JSONBody -Headers @{"Content-Type"="application/json"}

    }
}


Function Remove-VirtualServer{
<#

.SYNOPSIS
Remove the specified virtual server. Confirmation is needed. NB: Virtual server names are case-specific.

#>
    [CmdletBinding( SupportsShouldProcess=$true, ConfirmImpact="High")]    

    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$VirtualServerName
        
    )

    Write-Verbose "NB: Virtual server names are case-specific."

    #Build the URI for this pool
    $URI = $F5session.BaseURL + "virtual/$VirtualServerName"

    if ($pscmdlet.ShouldProcess($VirtualServerName)){

        #Check whether the specified virtual server exists
        If (!(Test-VirtualServer -F5session $F5session -VirtualServerName $VirtualServerName)){
            Write-Error "The $VirtualServerName virtual server does not exist."
        }

        Else {
  
            $response = Invoke-WebRequest -Insecure -Method DELETE -Uri "$URI" -Credential $F5session.Credential -Headers @{"Content-Type"="application/json"}

            If ($response.statusCode -eq "200"){
                $true;
            }
            Else {
                ("$($response.StatusCode): $($response.StatusDescription)")
            }

        }
    }

}


Function Get-PoolList{
#Get a list of all pools for the specified F5 LTM
    
    param (
        [Parameter(Mandatory=$true)]$F5session
    )

    #Only retrieve the pool names
    $PoolsPage = $F5session.BaseURL + 'pool/?$select=name'

    $PoolsJSON = Invoke-WebRequest -Insecure -Uri $PoolsPage -Credential $F5session.Credential

    $Pools = $PoolsJSON.Content | ConvertFrom-Json

    $Pools.items.name

}

Function Get-Pool {
#Retrieve the specified pool
#NB: Pool names are case-specific.
    
    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    Write-Verbose "NB: Pool names are case-specific."

    #Build the URI for this pool
    $URI = $F5session.BaseURL + "pool/$PoolName"

    $PoolJSON = Invoke-WebRequest -Insecure -Uri $URI -Credential $F5session.Credential -ErrorAction SilentlyContinue

    If ($PoolJSON){
        $Pool = $PoolJSON.Content | ConvertFrom-Json
        $Pool
    }
    Else {

        Write-Error ("The $PoolName pool does not exist.")
    }

}


Function Test-Pool {
#Test whether the specified pool exists
#NB: Pool names are case-specific.
    
    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    Write-Verbose "NB: Pool names are case-specific."

    #Build the URI for this pool
    $URI = $F5session.BaseURL + "pool/$PoolName"

    $PoolJSON = Invoke-WebRequest -Insecure -Uri $URI -Credential $F5session.Credential -ErrorAction SilentlyContinue

    If ($PoolJSON){
        $true
    }
    Else {
        $false
    }

}

Function New-Pool {
<#

.SYNOPSIS
Create a new pool. Optionally, add pool members to the new pool

.EXAMPLE
New-Pool -F5Session $F5Session -PoolName "MyPoolName" -MemberDefinitionList @("Server1,80,Web server","Server2,443,Another web server")

.DESCRIPTION
Expects the $MemberDefinitionList param to be an array of strings. 
Each string should contain a computer name and a port number, comma-separated.
Optionally, it can contain a description of the member.

#>   
    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [string[]]$MemberDefinitionList
    )


    $URI = ($F5session.BaseURL + "pool")

    #Check whether the specified pool already exists
    If (Test-Pool -F5session $F5session -PoolName $PoolName){
        Write-Error "The $PoolName pool already exists."
    }

    Else {


        #Start building the JSON for the action
        $JSONBody = @{name=$PoolName;partition='Common';members=@()}

        $Members = @()

        ForEach ($MemberDefinition in $MemberDefinitionList){

            #Build the member name from the IP address and the port
            $MemberObject = $MemberDefinition.Split(",")

            If ($MemberObject.Length -lt 2){
                Throw("All member definitions should consist of a string containing at least a computer name and a port, comma-separated.")
            }

            $IPAddress = Get-WmiObject -ComputerName $MemberObject[0] -Class Win32_NetworkAdapterConfiguration | Where DefaultIPGateway | select -exp IPaddress | select -first 1

            Try {
                $PortNumber = [int]$MemberObject[1]
            }
            Catch {
                $ThrowMessage = $MemberObject[1] + " is not a valid value for a port number."
                Throw($ThrowMessage)
            }

            If (($PortNumber -lt 0) -or ($PortNumber -gt 65535)){
                $ThrowMessage = $MemberObject[1] + " is not a valid value for a port number."
                Throw($ThrowMessage)
            }

            $Member = @{name=$($IPAddress + ":" + $PortNumber);address=$IPAddress;description=$($MemberObject[2])}
            $Members += $Member

        }

        $JSONBody.members = $Members
        $JSONBody = $JSONBody | ConvertTo-Json

        $response = Invoke-WebRequest -Insecure -Method POST -Uri "$URI" -Credential $F5session.Credential -Body $JSONBody -Headers @{"Content-Type"="application/json"}

    }

}


Function Remove-Pool{
#Remove the specified pool. Confirmation is needed
#NB: Pool names are case-specific.
    
    [CmdletBinding( SupportsShouldProcess=$true, ConfirmImpact="High")]    

    param (
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)][string]$PoolName
        
    )

    Write-Verbose "NB: Pool names are case-specific."

    #Build the URI for this pool
    $URI = $F5session.BaseURL + "pool/$PoolName"

    if ($pscmdlet.ShouldProcess($PoolName)){

        #Check whether the specified pool already exists
        If (!(Test-Pool -F5session $F5session -PoolName $PoolName)){
            Write-Error "The $PoolName pool does not exist."
        }

        Else {
  
            $response = Invoke-WebRequest -Insecure -Method DELETE -Uri "$URI" -Credential $F5session.Credential -Headers @{"Content-Type"="application/json"}

            If ($response.statusCode -eq "200"){
                $true;
            }
            Else {
                ("$($response.StatusCode): $($response.StatusDescription)")
            }

        }
    }

}



Function Get-PoolMemberCollection {
#Get the members of the specified pool
    param(
        [Parameter(Mandatory=$true)]$PoolName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $PoolMembersPage = $F5session.BaseURL + "pool/~Common~$PoolName/members/?"

    $PoolMembersJSON = Invoke-WebRequest -Insecure -Uri $PoolMembersPage -Credential $F5session.Credential

    $PoolMembers = $PoolMembersJSON.Content | ConvertFrom-Json

    $PoolMembers.items

}

Function Get-AllPoolMembersStatus {
#Get the status of all members of the specified pool

   param(
        [Parameter(Mandatory=$true)]$PoolName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $PoolMembers = Get-PoolMembers -PoolName $PoolName -F5session $F5session | Select-Object -Property name,session,state

    $PoolMembers
}




Function Get-PoolMember {
#Get all details about the specified computer, for all pools of which it is a member
    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $MemberInPools = Get-PoolsForMember -ComputerName $ComputerName -F5session $F5session

    $PoolMember = $null
 
    $PoolMember = ForEach ($Pool in $MemberInPools){

        $IPAddress = Get-PoolMemberIP -ComputerName $ComputerName -PoolName $Pool

        $PoolMemberURI = $F5session.BaseURL + "pool/~Common~$Pool/members/~Common~$IPAddress`?"

        $PoolMemberJSON = Invoke-WebRequest -Insecure -Uri $PoolMemberURI -Credential $F5session.Credential

        $PoolMemberJSON.Content | ConvertFrom-Json

    }

    $PoolMember

}


Function Set-PoolMemberDescription {
# Set the description value for the specified pool member
    param(

        $ComputerName,
        $PoolName,
        $F5Session,
        $Description
    )

    $IPAddress = Get-PoolMemberIP -ComputerName $ComputerName -PoolName $PoolName

    $URI = $F5session.BaseURL + "pool/~Common~$PoolName/members/$IPAddress"

    $JSONBody = @{description=$Description} | ConvertTo-Json

    $response = Invoke-WebRequest -Insecure -Method PUT -Uri "$URI" -Credential $F5session.Credential -Body $JSONBody -Headers @{"Content-Type"="application/json"}


}


Function Get-PoolMemberStatus {
#Get the current session and state values for the specified computer

   param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $PoolMember = Get-PoolMember -ComputerName $ComputerName -F5session $F5session

    $PoolMember = $PoolMember | Select-Object -Property name,session,state

    $PoolMember 
}



Function Get-PoolsForMember {
#Determine which pool(s) a server is in

    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$F5session
    )

    #All servers that are LTM pool members use the NIC with a default gateway as the IP that registers with the LTM
    $ComputerIP = Get-WmiObject -ComputerName $ComputerName -Class Win32_NetworkAdapterConfiguration | Where DefaultIPGateway | select -exp IPaddress | select -first 1
    
    $AllPools = Get-PoolList -F5session $F5session

    $PoolsFound = @()

    foreach($Pool in $AllPools) 
    {
        $PoolMembers = Get-PoolMembers -PoolName $Pool -F5session $F5session

        foreach($PoolMember in $PoolMembers) {

            if($PoolMember.address -eq $ComputerIP) {
                $PoolsFound += $Pool
            }
        }

    }

    $PoolsFound
}


Function Get-PoolMemberIP {
#Determine the IP address and port for a server in a particular pool

    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$PoolName
    )


    $IPAddress = Get-WmiObject -ComputerName $ComputerName -Class Win32_NetworkAdapterConfiguration | Where DefaultIPGateway | select -exp IPaddress | select -first 1

    $Port = $PoolName -replace ".*_",""

    If ($IPAddress -eq $null){
        throw ("This server $ComputerName was not found, or its NIC(s) don't have a default gateway.")
    }
    Else {
        ($IPAddress+":"+$Port)
    }
}



Function Add-PoolMember{
#Add a computer to a pool as a member
    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$PoolName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $URI = $F5session.BaseURL + "pool/~Common~$PoolName/members"

    $IPAddress = Get-WmiObject -ComputerName $ComputerName -Class Win32_NetworkAdapterConfiguration | Where DefaultIPGateway | select -exp IPaddress | select -first 1
    $MemberName = $IPAddress + ":" + ($PoolName -replace ".*_","")

    $JSONBody = @{name=$MemberName;address=$IPAddress;description=$ComputerName} | ConvertTo-Json

    $response = Invoke-WebRequest -Insecure -Method POST -Uri "$URI" -Credential $F5session.Credential -Body $JSONBody -Headers @{"Content-Type"="application/json"}

    If ($response.statusCode -eq "200"){
        $true;
    }
    Else {
        ("$($response.StatusCode): $($response.StatusDescription)")
    }
}


Function Remove-PoolMember{
#Remove a computer from a pool
    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$PoolName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $ComputerIP = Get-WmiObject -ComputerName $ComputerName -Class Win32_NetworkAdapterConfiguration | Where DefaultIPGateway | select -exp IPaddress | select -first 1
    $MemberName = $ComputerIP + ":" + ($PoolName -replace ".*_","")

    $URI = $F5session.BaseURL + "pool/~Common~$PoolName/members/~Common~$MemberName"
    
    $response = Invoke-WebRequest -Insecure -Method DELETE -Uri "$URI" -Credential $F5session.Credential -Headers @{"Content-Type"="application/json"}

    If ($response.statusCode -eq "200"){
        $true;
    }
    Else {
        ("$($response.StatusCode): $($response.StatusDescription)")
    }
}


Function Disable-PoolMember{
#Disable a pool member
    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$F5session,
        [switch]$Force
    )

    #If the -Force param is specified pool members do not accept any new connections, even if they match an existing persistence session.
    #Otherwise, members will only accept only new connections that match an existing persistence session.
    If ($Force){
        $AcceptNewConnections = "user-down"
    }
    Else {
        $AcceptNewConnections = "user-up"
    }

    $IPAddress = (Get-PoolMember -ComputerName $ComputerName -F5session $F5session).Name

    #Retrieve all pools of which this server is a member
    $Pools = Get-PoolsForMember -ComputerName $ComputerName -F5session $F5session


    $JSONBody = @{state=$AcceptNewConnections;session='user-disabled'} | ConvertTo-Json

    ForEach ($Pool in $Pools){
    
        $URI = $F5session.BaseURL + "pool/~Common~$Pool/members/$IPAddress"
        $response = Invoke-WebRequest -Insecure -Method Put -Uri "$URI" -Credential $F5session.Credential -Body $JSONBody

    }
    
}


Function Enable-PoolMember {
#Enable a pool member
    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$F5session
    )

    $Pools = Get-PoolsForMember -ComputerName $ComputerName -F5session $F5session
    $IPAddress = (Get-PoolMember -ComputerName $ComputerName -F5session $F5session).Name

    ForEach ($Pool in $Pools){

        $URI = $F5session.BaseURL + "pool/~Common~$Pool/members/$IPAddress"
        $response = Invoke-WebRequest -Insecure -Method Put -Uri "$URI" -Credential $F5session.Credential -Body '{"state": "user-up", "session": "user-enabled"}'

    }

}


Function Get-CurrentConnectionCount {
#Get the count of the specified pool member's current connections
    param(
        [Parameter(Mandatory=$true)]$ComputerName,
        [Parameter(Mandatory=$true)]$PoolName,
        [Parameter(Mandatory=$true)]$F5session

    )

    $IPAddress = (Get-PoolMember -ComputerName $ComputerName -F5session $F5session).Name

    $PoolMember = $F5session.BaseURL + "pool/~Common~$PoolName/members/~Common~$IPAddress/stats"


    $PoolMemberJSON = Invoke-WebRequest -Insecure -Uri $PoolMember -Credential $F5session.Credential

    $PoolMember = $PoolMemberJSON.Content | ConvertFrom-Json

    #Return the number of current connections for this member of this pool
    $PoolMember.entries.'serverside.curConns'.value

}

Function Get-StatusShape {
#Determine the shape to display for a member's current state and session values
    param(
        [Parameter(Mandatory=$true)]$state,
        [Parameter(Mandatory=$true)]$session
    )

    #Determine status shape based on state and session values
    If ($state -eq "up" -and $session -eq "monitor-enabled"){
        $StatusShape = "green-circle"
    }
    ElseIf ($state -eq "up" -and $session -eq "user-disabled"){
        $StatusShape = "black-circle"
    }
    ElseIf ($state -eq "user-down" -and $session -eq "user-disabled"){
        $StatusShape = "black-diamond"
    }
    ElseIf ($state -eq "down" -and $session -eq "monitor-enabled"){
        $StatusShape = "red-diamond"
    }
    ElseIf ($state -eq "unchecked" -and $session -eq "user-enabled"){
        $StatusShape = "blue-square"
    }
    ElseIf ($state -eq "unchecked" -and $session -eq "user-disabled"){
        $StatusShape = "black-square"
    }
    Else{
        #Unknown
        $StatusShape = "black-square"
    }
        
    $StatusShape
}


Function Get-VirtualServeriRuleCollection {
#Get the iRules currently applied to the specified virtual servers    
#This function assumes everything is in the /Common partition
    param(
        [Parameter(Mandatory=$true)]$VirtualServer,
        [Parameter(Mandatory=$true)]$F5session
    )

    $VirtualServerURI = $F5session.BaseURL + "virtual/~Common~$VirtualServer/"

    $VirtualserverObject = Invoke-WebRequest -Insecure -Uri $VirtualServerURI -Credential $F5session.Credential

    $VirtualserverObjectContent = $VirtualserverObject.Content | ConvertFrom-Json

    #Filter the content for just the iRules
    $VirtualserverObjectContent = $VirtualserverObjectContent | Select-Object -Property rules

    $iRules = $VirtualserverObjectContent.rules

    #If the existing iRules collection is not an array, then convert it to one before returning
    If ($iRules -isnot [system.array]){
        $iRulesArray = @()
        $iRulesArray += $iRules
    }
    Else {
        $iRulesArray = $iRules
    }

    $iRulesArray

}

Function Add-iRuleToVirtualServer {
#Add an iRule to the specified virtual server
#This function assumes everything is in the /Common partition
    param(
        [Parameter(Mandatory=$true)]$VirtualServer,
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)]$iRule
    )

    $iRuleToAdd = "/Common/$iRule"

    #Get the existing IRules on the virtual server
    [array]$iRules = Get-VirtualServerIRuleCollection -VirtualServer $VirtualServer -F5session $F5session

    #If there are no iRules on this virtual server, then create a new array
    If (!$iRules){
        $iRules = @()
    }        

    #Check that the specified iRule is not already in the collection 
    If ($iRules -match $iRuleToAdd){
        Write-Warning "The $VirtualServer virtual server already contains the $iRule iRule."
        Return($false)
    }
    Else {
        $iRules += $iRuleToAdd

        $VirtualserverIRules = $F5session.BaseURL + "virtual/~Common~$VirtualServer/"

        $JSONBody = @{rules=$iRules} | ConvertTo-Json

        $response = Invoke-WebRequest -Insecure -Method PUT -Uri "$VirtualserverIRules" -Credential $F5session.Credential -Body $JSONBody -Headers @{"Content-Type"="application/json"}

        Return($true)

    }


}

Function Remove-iRuleFromVirtualServer {
#Remove an iRule from the specified virtual server
#This function assumes everything is in the /Common partition
    param(
        [Parameter(Mandatory=$true)]$VirtualServer,
        [Parameter(Mandatory=$true)]$F5session,
        [Parameter(Mandatory=$true)]$iRule
    )

    $iRuleToRemove = "/Common/$iRule"

    #Get the existing IRules on the virtual server
    [array]$iRules = Get-VirtualServerIRules -VirtualServer $VirtualServer -F5session $F5session

    #If there are no iRules on this virtual server, then create a new array
    If (!$iRules){
        $iRules = @()
    }  

    #Check that the specified iRule is in the collection 
    If ($iRules -match $iRuleToRemove){

        $iRules = $iRules | Where-Object { $_ -ne $iRuleToRemove }

        $VirtualserverIRules = $F5session.BaseURL + "virtual/~Common~$VirtualServer/"

        $JSONBody = @{rules=$iRules} | ConvertTo-Json

        $response = Invoke-WebRequest -Insecure -Method PUT -Uri "$VirtualserverIRules" -Credential $F5session.Credential -Body $JSONBody -Headers @{"Content-Type"="application/json"}

        Return($true)

    }
    Else {
        Write-Warning "The $VirtualServer virtual server does not contain the $iRule iRule."

        Return($false)

    }

}


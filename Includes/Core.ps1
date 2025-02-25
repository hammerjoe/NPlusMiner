<#
This file is part of NPlusMiner
Copyright (c) 2018 Nemo
Copyright (c) 2018-2021 MrPlus

NPlusMiner is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

NPlusMiner is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
#>

<#
Product:        NPlusMiner
File:           Core.ps1
version:        5.9.9
version date:   20191110
#>

Function InitApplication {
    $Variables.SourcesHash = @()
    $Variables.ProcessorCount = ((Get-WmiObject -class win32_processor).NumberOfLogicalProcessors | Measure-Object -Sum).Sum
	$Variables.IsAdminSession = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    $ServerPasswd = ConvertTo-SecureString $Config.Server_Password -AsPlainText -Force
    $ServerCreds = New-Object System.Management.Automation.PSCredential ($Config.Server_User, $ServerPasswd)
    $Variables.ServerCreds = $ServerCreds
    $ServerClientPasswd = ConvertTo-SecureString $Config.Server_ClientPassword -AsPlainText -Force
    $ServerClientCreds = New-Object System.Management.Automation.PSCredential ($Config.Server_ClientUser, $ServerClientPasswd)
    $Variables.ServerClientCreds = $ServerClientCreds

    if (!(IsLoaded(".\Includes\include.ps1"))) {. .\Includes\include.ps1;RegisterLoaded(".\Includes\include.ps1")}
    if (!(IsLoaded(".\Includes\Server.ps1"))) {. .\Includes\Server.ps1;RegisterLoaded(".\Includes\Server.ps1")}
    Set-Location (Split-Path $script:MyInvocation.MyCommand.Path)

    $Variables.ScriptStartDate = (Get-Date)
    # GitHub Supporting only TLSv1.2 on feb 22 2018
    [Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"
    Set-Location (Split-Path $script:MyInvocation.MyCommand.Path)
    <# Removed as duplicative and slows down start up;  next command does the same thing #> 
    # Get-ChildItem . -Recurse | Unblock-File

    # Check if running as administrator and set variable
    $windowsIdentity    = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $wi_principal       = New-Object System.Security.Principal.WindowsPrincipal($windowsIdentity)
    $administratorRole  = [System.Security.Principal.WindowsBuiltInRole]::Administrator
    if ( $wi_principal.IsInRole($administratorRole) ) {
        $IsUserAdmin = $true
    }
    else {
        $IsUserAdmin = $False
    }

    if (Get-Command "Unblock-File" -ErrorAction SilentlyContinue) { Get-ChildItem . -Recurse | Unblock-File }
    if ((Get-Command "Get-MpPreference" -ErrorAction SilentlyContinue) -and (Get-MpPreference).ExclusionPath -notcontains (Convert-Path .) -and $IsUserAdmin -and (-not (Test-Path ".\Logs\switching.log"))) {
        Start-Process (@{desktop = "powershell"; core = "pwsh" }.$PSEdition) "-Command Import-Module '$env:Windir\System32\WindowsPowerShell\v1.0\Modules\Defender\Defender.psd1'; Add-MpPreference -ExclusionPath '$(Convert-Path .)'" -Verb runAs
    }

    if($Proxy -eq ""){$PSDefaultParameterValues.Remove("*:Proxy")}
    else{$PSDefaultParameterValues["*:Proxy"] = $Proxy}
    Update-Status("Initializing Variables...")
    $Variables.DecayStart = Get-Date
    $Variables.DecayPeriod = 120 #seconds
    $Variables.DecayBase = 1-0.1 #decimal percentage
    # $Variables | Add-Member -Force @{ActiveMinerPrograms = @()}
    $Variables["ActiveMinerPrograms"] = [System.Collections.ArrayList]::Synchronized(@())
    # $Variables | Add-Member -Force @{Miners = @()}
    # $Variables["Miners"] = [System.Collections.ArrayList]::Synchronized(@())
    #Start the log
        Start-Transcript -Path ".\Logs\miner-$((Get-Date).ToString('yyyyMMdd')).log" -Append -Force
    # Purge Logs more than 10 days
        If ((ls ".\logs\miner-*.log").Count -gt 10) {
            ls ".\Logs\miner-*.log" | Where {$_.name -notin (ls ".\Logs\miner-*.log" | sort LastWriteTime -Descending | select -First 10).FullName} | Remove-Item -Force -Recurse
        }
    #Update stats with missing data and set to today's date/time
    if(Test-Path "Stats"){Get-ChildItemContent "Stats" | ForEach {$Stat = Set-Stat $_.Name $_.Content.Week}}
    #Set donation parameters
    # $Variables | Add-Member -Force @{DonateRandom = [PSCustomObject]@{}}
    $Variables.LastDonated = (Get-Date).AddHours(-12).AddHours(1)
    # If ($Config.Donate -lt 3) {$Config.Donate = (0,(3..8)) | Get-Random}
    # $Variables | Add-Member -Force @{WalletBackup = $Config.Wallet}
    # $Variables | Add-Member -Force @{UserNameBackup = $Config.UserName}
    # $Variables | Add-Member -Force @{WorkerNameBackup = $Config.WorkerName}
    # $Variables | Add-Member -Force @{EarningsPool = ""}
    $Variables.BrainJobs = @()
    $Variables.EarningsTrackerJobs = @()
    $Variables.Earnings = [hashtable]::Synchronized(@{})

    
    $Global:Variables.StartPaused = $False
    $Global:Variables.Started = $False
    $Global:Variables.Paused = $False
    $Global:Variables.RestartCycle = $False

    
    $Location = $Config.Location
 
    # Find available TCP Ports
    $StartPort = 4068
    $Config.Type | sort | foreach {
        Update-Status("Finding available TCP Port for $($_)")
        $Port = Get-FreeTcpPort($StartPort)
        $Variables."$($_)MinerAPITCPPort" = $Port
        Update-Status("Miners API Port: $($Port)")
        $StartPort = $Port+1
    }
    Sleep 2
    
    # Register Rig on Server
    # need to decide on solution for IP address... Should be in config has could be external IP...
    # If ($Config.Server_Client) {
        # (Invoke-WebRequest "http://$($Config.Server_ClientIP):$($Config.Server_ClientPort)/RegisterRig/?name=$($Config.WorkerName)&IP=192.168.0.30&port=$($Config.ServerPort)" -Credential $Variables.ServerClientCreds)
    # }
    
    # Copy nvml.dll to proper location as latest drivers miss it
    # If ( (! (Test-Path "C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll")) -and (Test-Path "c:\Windows\System32\nvml.dll") ) {
        # Copy-Item "c:\Windows\System32\nvml.dll" "C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll" -Force -ErrorAction Ignore
    # }
}

Function Start-ChildJobs {
        # Stop Server on code updates
        If ($Config.Server_On -and $Variables.LocalServerRunning -and -not (IsLoaded(".\Includes\Server.ps1"))) {
            $Variables.StatusText = "Stopping server for code update."
            Invoke-WebRequest "http://localhost:$($Config.Server_Port)/StopServer" -Credential $Variables.ServerCreds -UseBasicParsing
            $Variables.LocalServerRunning = $False
        }
        
        If ($Variables.LocalServerRunning) {$Variables.StartServerAttempt = 0}
        
        # Starts Server if necessary
        If ($Config.Server_On -and -not $Variables.LocalServerRunning -and $Variables.StartServerAttempt -lt 5 ) {
            . .\Includes\Server.ps1;RegisterLoaded(".\Includes\Server.ps1")
            $Variables.StatusText = "Starting Server"
            $Variables.StopServer = $False
            Start-Server
            $Variables.StartServerAttempt++
            $Variables.LocalServerRunning = Try { ((Invoke-WebRequest "http://localhost:$($Config.Server_Port)/ping" -Credential $Variables.ServerCreds -UseBasicParsing).content -eq "Server Alive")} Catch {$False} 
        }
        
        # Starts Brains if necessary
        $Config.PoolName | foreach { if ($_ -notin $Variables.BrainJobs.PoolName){
            $BrainPath = "$($Variables.MainPath)\BrainPlus\$($_)"
            $BrainName = (".\BrainPlus\"+$_+"\BrainPlus.ps1")
            if (Test-Path $BrainName){
                $Variables.StatusText = "Starting BrainPlus for $($_)"
                $BrainJob = Start-Job -FilePath $BrainName -ArgumentList @($BrainPath)
                $BrainJob | Add-Member -Force @{PoolName = $_}
                $Variables.BrainJobs += $BrainJob
                rv BrainJob
            }
        }}
        # Starts Earnings Tracker Job if necessary
        $StartDelay = 0
        # if ($Config.TrackEarnings -and (($EarningTrackerConfig.Pools | sort) -ne ($Config.PoolName | sort))) {
            # $Variables.StatusText = "Updating Earnings Tracker Configuration"
            # $EarningTrackerConfig = Get-Content ".\Config\EarningTrackerConfig.json" | ConvertFrom-JSON
            # $EarningTrackerConfig | Add-Member -Force @{"Pools" = ($Config.PoolName)}
            # $EarningTrackerConfig | ConvertTo-JSON | Out-File ".\Config\EarningTrackerConfig.json"
        # }
        
        if (($Config.TrackEarnings) -and (!($Variables.EarningsTrackerJobs))) {
            $Params = @{
                WorkingDirectory = ($Variables.MainPath)
                PoolsConfig = $Config.PoolsConfig
            }
            $EarningsJob = Start-Job -FilePath ".\Includes\EarningsTrackerJob.ps1" -ArgumentList $Params
            If ($EarningsJob){
                $Variables.StatusText = "Starting Earnings Tracker"
                $Variables.EarningsTrackerJobs += $EarningsJob
                rv EarningsJob
                # Delay Start when several instances to avoid conflicts.
            }
        }
}

Function NPMCycle {
# $CycleTime = Measure-Command -Expression {
$CycleScriptBlock =  {
    [Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"
    if (!(IsLoaded(".\Includes\include.ps1"))) {. .\Includes\include.ps1;RegisterLoaded(".\Includes\include.ps1");"LoadedInclude" | out-host}
    
    (Get-Date).ToString() | out-host
    
    $Variables.EndLoop = $False

        $Variables.StatusText = "Starting Cycle"
        If ($Config.Server_Client) {
            $Variables.ServerRunning = Try{ ((Invoke-WebRequest "http://$($Config.Server_ClientIP):$($Config.Server_ClientPort)/ping" -Credential $Variables.ServerClientCreds -TimeoutSec 3 -UseBasicParsing).content -eq "Server Alive")} Catch {$False} 
            If ($Variables.ServerRunning){
                If ($Config.Server_ClientIP -and $Config.Server_ClientPort) {
                    Try {
                        Invoke-WebRequest "http://$($Config.Server_ClientIP):$($Config.Server_ClientPort)/RegisterRig/?Name=$($Config.WorkerName)&Port=$($Config.Server_Port)" -Credential $Variables.ServerClientCreds -TimeoutSec 5 -UseBasicParsing
                    } Catch {"INFO: Failed to register on http://$($Config.Server_ClientIP):$($Config.Server_ClientPort)/RegisterRig/?Name=$($Config.WorkerName)&Port=$($Config.Server_Port)" | out-host}
                }
                Try {
                    $PeersFromServer = Invoke-WebRequest "http://$($Config.Server_ClientIP):$($Config.Server_ClientPort)/Peers.json" -Credential $Variables.ServerClientCreds -UseBasicParsing | convertfrom-json
                    # $PeersFromServer | ? {$_.Name -ne $Config.WorkerName} | ForEach {
                    $PeersFromServer | ForEach {
                        $RegServer = $_.IP
                        $RegPort = $_.Port
                        Invoke-WebRequest "http://$($RegServer):$($RegPort)/RegisterRig/?Name=$($Config.WorkerName)&Port=$($Config.Server_Port)" -Credential $Variables.ServerClientCreds -TimeoutSec 5 -UseBasicParsing
                    }
                } Catch {"INFO: Failed to register on http://$($RegServer):$($RegPort)/RegisterRig/?Name=$($Config.WorkerName)&Port=$($Config.Server_Port)" | out-host}
            }
        }
        $DecayExponent = [int](((Get-Date)-$Variables.DecayStart).TotalSeconds/$Variables.DecayPeriod)

        # Ensure we get the hashrate for running miners prior looking for best miner
        $Variables["ActiveMinerPrograms"] | ForEach {
            if($_.Process -eq $null -or $_.Process.HasExited)
            {
                if($_.Status -eq "Running"){$_.Status = "Failed";$_.FailedCount++}
            }
            else
            {
                # we don't want to store hashrates if we run less than $Config.StatsInterval sec
                $WasActive = [math]::Round(((Get-Date)-$_.Process.StartTime).TotalSeconds)
                if ($WasActive -ge $Config.StatsInterval) {
                    $_.HashRate = 0
                    $Miner_HashRates = $null
                    if($_.New){$_.Benchmarked++}         
                    $Miner_HashRates = Get-HashRate $_.API $_.Port ($_.New -and $_.Benchmarked -lt 3)
                    $_.HashRate = $Miner_HashRates | Select -First $_.Algorithms.Count           
                    if($Miner_HashRates.Count -ge $_.Algorithms.Count)
                    {
                        for($i = 0; $i -lt $_.Algorithms.Count; $i++)
                        {
                            $Stat = Set-Stat -Name "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate" -Value ($Miner_HashRates | Select -Index $i)
                        }
                        $_.New = $false
                        $_.Hashrate_Gathered = $true
                        "Stats $($_.Algorithms) -> $($Miner_HashRates | ConvertTo-Hash) after $($WasActive) sec" | out-host
                    }
                }
            }
        }
        
        #Activate or deactivate donation
        if((Get-Date).AddHours(-12) -ge $Variables.LastDonated -and $Variables.DonateRandom.wallet -eq $Null){
            # Get donation addresses randomly from agreed developers list
            # This will fairly distribute donations to Developers
            # Developers list and wallets is publicly available at: http://tiny.cc/r355qy 
            $Variables.StatusText = "ENTERING DONATION"
            $Variables.DonationStart = $True 
            $Variables.DonationRunning = $False 
            $Config.PartyWhenAvailable = $False
            try {$Donation = Invoke-WebRequest "http://tiny.cc/r355qy" -TimeoutSec 15 -UseBasicParsing -Headers $Variables.APIHeaders | ConvertFrom-Json} catch {$Donation = @([PSCustomObject]@{Name = "mrplus";Wallet = "134bw4oTorEJUUVFhokDQDfNqTs7rBMNYy";UserName = "mrplus"},[PSCustomObject]@{Name = "nemo";Wallet = "1QGADhdMRpp9Pk5u5zG1TrHKRrdK5R81TE";UserName = "nemo"})}
            if ($Donation -ne $null) {
                If ($Config.Donate -lt 3) {$Config.Donate = (0,(3..8)) | Get-Random}
                $Variables.DonateRandom = $Donation | Get-Random
                $DevPoolsConfig = [PSCustomObject]@{default = [PSCustomObject]@{Wallet = $Variables.DonateRandom.Wallet;UserName = $Variables.DonateRandom.UserName;WorkerName = "$($Variables.CurrentProduct)$($Variables.CurrentVersion.ToString().replace('.',''))";PricePenaltyFactor=1}}
                $Config | Add-Member -Force @{PoolsConfig = Merge-PoolsConfig -Main $Config.PoolsConfig -Secondary $DevPoolsConfig}
                If ($Variables.DonateRandom.Donate) {$Config.Donate = $Variables.DonateRandom.Donate}
                $Variables.DonationEndTime = (Get-Date).AddMinutes($Config.Donate) 
                If ($Variables.DonateRandom.PoolsConfURL) {
                    # Get Dev Pools Config
                    try {
                        $DevPoolsConfig = Invoke-WebRequest $Variables.DonateRandom.PoolsConfURL -TimeoutSec 15 -UseBasicParsing -Headers $Variables.APIHeaders | ConvertFrom-Json
                    } catch {
                        $DevPoolsConfig = [PSCustomObject]@{default = [PSCustomObject]@{Wallet = $Variables.DonateRandom.Wallet;UserName = $Variables.DonateRandom.UserName;WorkerName = "$($Variables.CurrentProduct)$($Variables.CurrentVersion.ToString().replace('.',''))";PricePenaltyFactor=1}}
                    }
                    If ($DevPoolsConfig -ne $null) {
                        $DevPoolsConfig | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name | foreach { $DevPoolsConfig.$_.WorkerName = "$($Variables.CurrentProduct)$($Variables.CurrentVersion.ToString().replace('.',''))" }
                        $Config | Add-Member -Force @{PoolsConfig = Merge-PoolsConfig -Main $Config.PoolsConfig -Secondary $DevPoolsConfig}
                        If ( $Variables.DonateRandom.ForcePoolList -and (Compare-Object ((Get-ChildItem ".\Pools").BaseName | sort -Unique) $Variables.DonateRandom.PoolList -IncludeEqual -ExcludeDifferent)) {
                            $Config.PoolName = $Variables.DonateRandom.PoolList
                        }
                        rv DevPoolsConfig
                    }
                }
            }
        }
        if(((Get-Date) -ge $Variables.DonationEndTime -and $Variables.DonateRandom.Wallet -ne $Null) -or (! $Config.PoolsConfig)){
            If ($Variables.DonationStart -or $Variables.DonationRunning) {$Variables.StatusText = "EXITING DONATION"}
            $Variables.DonationStart = $False 
            $Variables.DonationRunning = $False 
            $ConfigLoad = Get-Content $Config.ConfigFile | ConvertFrom-json
            $ConfigLoad | % {$_.psobject.properties | sort Name | % {$Config | Add-Member -Force @{$_.Name = $_.Value}}}
            $Config | Add-Member -Force -MemberType ScriptProperty -Name "PoolsConfig" -Value {
                If (Test-Path ".\Config\PoolsConfig.json"){
                    get-content ".\Config\PoolsConfig.json" | ConvertFrom-json
                }else{
                    [PSCustomObject]@{default=[PSCustomObject]@{
                        Wallet = "134bw4oTorEJUUVFhokDQDfNqTs7rBMNYy"
                        UserName = "mrplus"
                        WorkerName = "NPlusMinerNoCfg"
                        PoolPenalty = 1
                    }}
                }
            }
            $Variables.LastDonated = Get-Date
            $Variables.DonateRandom = [PSCustomObject]@{}
        }
        $Variables.StatusText = "Loading currencies rate from 'api.coinbase.com'.."
        Try{
            # $Rates = Invoke-RestMethod "https://api.coinbase.com/v2/exchange-rates?currency=BTC" -TimeoutSec 15 -UseBasicParsing | Select-Object -ExpandProperty data | Select-Object -ExpandProperty rates
            $Rates = Invoke-ProxiedWebRequest "https://api.coinbase.com/v2/exchange-rates?currency=$($Config.Passwordcurrency)" -TimeoutSec 15 -UseBasicParsing | convertfrom-json | Select-Object -ExpandProperty data | Select-Object -ExpandProperty rates
            $Config.Currency.Where( {$Rates.$_} ) | ForEach-Object {$Rates | Add-Member $_ ([Double]$Rates.$_) -Force}
            $Variables.Rates = $Rates
        } catch {$Variables.StatusText = "Minor error - Failed to load BTC rate.."}
        #Load the Stats
        $Stats = [PSCustomObject]@{}
        if(Test-Path "Stats"){Get-ChildItemContent "Stats" | ForEach {$Stats | Add-Member $_.Name $_.Content}}
        #Load information about the Pools
        $Variables.StatusText = "Loading pool stats.."
        $PoolFilter = @()
        $Config.PoolName | foreach {$PoolFilter+=($_+=".*")}
        Do {
            $Tries++
            $AllPools = if(Test-Path "Pools"){[System.Collections.ArrayList]::Synchronized(@(Get-SubScriptContent "Pools" -Include $PoolFilter)).Where({$_.Content -ne $Null}) | ForEach {$_.Content | Add-Member @{Name = $_.Name} -PassThru} | 
                Where {
                    $_.SSL -EQ $Config.SSL -and ($Config.PoolName.Count -eq 0 -or ($_.Name -in $Config.PoolName)) -and (!$Config.Algorithm -or ((!($Config.AlgoInclude) -or $_.Algorithm -in $Config.AlgoInclude) -and (!($Config.AlgoExclude) -or $_.Algorithm -notin $Config.AlgoExclude)))
                }
            }
                if ($AllPools.Count -eq 0) {
                $Variables.StatusText = "Waiting for pool data. retrying in 30 seconds.."
                Sleep 30
            }
        } While ($AllPools.Count -eq 0 -and $Tries -le 3)
        $Tries = 0
        $Variables.StatusText = "Computing pool stats.."
        # Use location as preference and not the only one
        $AllPoolsTemp = $AllPools
        $AllPools = @(@($AllPools).Where({$_.location -eq $Config.Location}))
        # $AllPools = $AllPools + @($AllPoolsTemp.Where({$_.name -notin $AllPools.name}))
        $AllPools += (@($AllPoolsTemp | sort name,algorithm,coin -Unique).Where({$_.name -notin ($AllPools.name | Sort -Unique)}))
        # rv LocPools
        # Filter Algo based on Per Pool Config
        $PoolsConf = $Config.PoolsConfig
        $AllPools = @($AllPools).Where({$_.Name -notin ($PoolsConf | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name) -or ($_.Name -in ($PoolsConf | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name) -and ((!($PoolsConf.($_.Name).Algorithm | ? {$_ -like "+*"}) -or ("+$($_.Algorithm)" -in $PoolsConf.($_.Name).Algorithm)) -and ("-$($_.Algorithm)" -notin $PoolsConf.($_.Name).Algorithm)))})
		# Filter pools based on max TTF
		# PoolsConfig value will prevail over $Config if exists
		$AllPools = @($AllPools).Where({
			If ($PoolsConf.($_.Name).MaxTTFSeconds -and $PoolsConf.($_.Name).MaxTTFSeconds -ge 0){
				((!($_.Real_ttf)) -or ($_.Real_ttf -le $PoolsConf.($_.Name).MaxTTFSeconds))
			} Elseif ($Config.MaxTTFSeconds -and $Config.MaxTTFSeconds -ge 0 -and (!($PoolsConf.($_.Name).MaxTTFSeconds))) {
				(!($_.Real_ttf)) -or ($_.Real_ttf -le $Config.MaxTTFSeconds)
			} Else {
				$_.name -ne $null
			}
		})

    # if($AllPools.Count -eq 0){$Variables.StatusText = "Error contacting pool, retrying.."; $timerCycle.Interval = 15000 ; $timerCycle.Start() ; return}
        $Pools = [PSCustomObject]@{}
        $Pools_Comparison = [PSCustomObject]@{}
        $AllPools.Algorithm | Sort -Unique | ForEach {
            $Algo = $_
            # $Pools | Add-Member $_ ($AllPools | Where Algorithm -EQ $_ | Sort Price -Descending | Select -First 1)
            # $Pools_Comparison | Add-Member $_ ($AllPools | Where Algorithm -EQ $_ | Sort StablePrice -Descending | Select -First 1)
            $Pools | Add-Member $_ ($AllPools.Where({ $_.Algorithm -EQ $Algo }) | Sort Price -Descending)
            $Pools_Comparison | Add-Member $_ ($AllPools.Where({ $_.Algorithm -EQ $Algo }) | Sort StablePrice -Descending)
        }
        # $AllPools.Algorithm | Select -Unique | ForEach {$Pools_Comparison | Add-Member $_ ($AllPools | Where Algorithm -EQ $_ | Sort StablePrice -Descending | Select -First 1)}
        #Load information about the Miners
        #Messy...?
        
        # $Variables.StatusText = "Looking for Miners file changes.."
        if (!($Variables.MinersHash)){
            If (Test-Path ".\Config\MinersHash.json") 
                {$Variables.MinersHash = Get-Content ".\Config\MinersHash.json" | ConvertFrom-Json
            } else {
                $Variables.MinersHash = Get-ChildItem .\Miners\ -filter "*.ps1" | Get-FileHash
                $Variables.MinersHash | ConvertTo-Json | out-file ".\Config\MinersHash.json"
            }
        } else {
            Compare-Object $Variables.MinersHash (Get-ChildItem .\Miners\ -filter "*.ps1" | Get-FileHash) -Property "Hash","Path" | Sort "Path" -Unique | % {
                $Variables.StatusText = "Miner Updated: $($_.Path)"
                $NewMiner =  &$_.path | select -first 1
                $NewMiner | Add-Member -Force @{Name = (Get-Item $_.Path).BaseName}
                If ($NewMiner.Path -and (Test-Path (Split-Path $NewMiner.Path))) {
                    $Variables["ActiveMinerPrograms"].Where( { $_.Status -eq "Running" -and (Resolve-Path $_.Path).Path -eq (Resolve-Path $NewMiner.Path).Path} ) | ForEach {
                            if($_.Process -eq $null)
                            {
                                $_.Status = "Failed"
                                $_.FailedCount++
                            }
                            elseif($_.Process.HasExited -eq $false)
                            {
                               $_.Process.CloseMainWindow() | Out-Null
                               Sleep 1
                               # simply "Kill with power"
                               Stop-Process $_.Process -Force | Out-Null
                               $Variables.StatusText = "closing current miner for Update"
                               Sleep 1
                               $_.Status = "Idle"
                            }
                            #Restore Bias for non-active miners
                            $Object = $_
                            $Variables["Miners"].Where({ $_.Path -EQ $Object.Path -and $_.Arguments -EQ $Object.Arguments }) | ForEach {$_.Profit_Bias = $_.Profit_Bias_Orig}
                    }
                    # Force re-benchmark - Deactivated
                    # Get-ChildItem -path ".\stats\" -filter "$($NewMiner.Name)_*.txt" | Remove-Item -Force -Recurse
                    Remove-Item -Force -Recurse (Split-Path $NewMiner.Path)
                }
                $Variables.MinersHash = Get-ChildItem .\Miners\ -filter "*.ps1" | Get-FileHash
                $Variables.MinersHash | ConvertTo-Json | out-file ".\Config\MinersHash.json"
            }
        }

        
        $Variables.StatusText = "Loading miners.."
        # $Variables | Add-Member -Force @{Miners = @()}
        $StartPort=4068
    
    # Better load here than in miner file. Reduces disk reads.
    # $MinersConfig = If (Test-Path ".\Config\MinersConfig.json") { Get-content ".\Config\MinersConfig.json" | convertfrom-json }
    $Script:MinerCustomConfig = Get-Content ".\Config\MinerCustomConfig.json" | ConvertFrom-Json
    $Script:MinerCustomConfigCode = Get-Content ".\Includes\MinerCustomConfig.ps1" -raw
    $i = 0
    $Variables["Miners"] = if (Test-Path "Miners") {
        [System.Collections.ArrayList]::Synchronized(@(
            Get-SubScriptContent "Miners"
            if ($Config.IncludeOptionalMiners -and (Test-Path "OptionalMiners")) {Get-SubScriptContent "OptionalMiners"}
            if (Test-Path "CustomMiners") { Get-SubScriptContent "CustomMiners"}
        )).Where({ $_.Content.Host -ne $Null -and $_.Content.Type -in $Config.Type }).ForEach({
                $Miner = $_.Content | Add-Member @{Name = $_.Name} -PassThru

                # $Miner = $_
                $Miner_HashRates = [PSCustomObject]@{}
                $Miner_Pools = [PSCustomObject]@{}
                $Miner_Pools_Comparison = [PSCustomObject]@{}
                $Miner_Profits = [PSCustomObject]@{}
                $Miner_Profits_Comparison = [PSCustomObject]@{}
                $Miner_Profits_Bias = [PSCustomObject]@{}
                $Miner_Types = $Miner.Type | Select -Unique
                $Miner_Indexes = $Miner.Index | Select -Unique
                # $Miner.HashRates | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name | ForEach {
                    # $LocPool = $Pools.$_ | Where {$_.Host -eq $Miner.Host -and $_.Coin -eq $Miner.Coin}
                    # $LocPoolsComp = $Pools_Comparison.$_ | Where {$_.Host -eq $Miner.Host -and $_.Coin -eq $Miner.Coin}
                    # $Miner_HashRates | Add-Member $_ ([Double]$Miner.HashRates.$_)
                    # $Miner_Pools | Add-Member $_ ([PSCustomObject]$LocPool)
                    # $Miner_Pools_Comparison | Add-Member $_ ([PSCustomObject]$LocPoolsComp | Where {$_.Host -eq $Miner.Host -and $_.Coin -eq $Miner.Coin})
                    # $Miner_Profits | Add-Member $_ ([Double]$Miner.HashRates.$_*$LocPool.Price)
                    # $Miner_Profits_Comparison | Add-Member $_ ([Double]$Miner.HashRates.$_*$LocPoolsComp.Price)
                    # $Miner_Profits_Bias | Add-Member $_ ([Double]$Miner.HashRates.$_*$LocPool.Price*(1-($Config.MarginOfError*[Math]::Pow($Variables.DecayBase,$DecayExponent))))
                # }
                $Miner.HashRates | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name | ForEach {
                    $LocPool = $Pools.$_ | Where {$_.Host -in $Miner.Host -and $_.Coin -in $Miner.Coin} 
                    $LocPoolsComp = $Pools_Comparison.$_ | Where {$_.Host -in $Miner.Host -and $_.Coin -in $Miner.Coin} 
                    $Miner_HashRates | Add-Member $_ ([Double]$Miner.HashRates.$_)
                    $Miner_Pools | Add-Member $_ ([PSCustomObject]$LocPool)
                    $Miner_Pools_Comparison | Add-Member $_ ([PSCustomObject]$LocPoolsComp | Where {$_.Host -in $Miner.Host -and $_.Coin -in $Miner.Coin} )
                    $Miner_Profits | Add-Member $_ ([Double]$Miner.HashRates.$_*$LocPool.Price)
                    $Miner_Profits_Comparison | Add-Member $_ ([Double]$Miner.HashRates.$_*$LocPoolsComp.Price)
                    $Miner_Profits_Bias | Add-Member $_ ([Double]$Miner.HashRates.$_*$LocPool.Price*(1-($Config.MarginOfError*[Math]::Pow($Variables.DecayBase,$DecayExponent))))
                }
                $Miner_Profit = [Double]($Miner_Profits.PSObject.Properties.Value | Measure -Sum).Sum
                $Miner_Profit_Comparison = [Double]($Miner_Profits_Comparison.PSObject.Properties.Value | Measure -Sum).Sum
                $Miner_Profit_Bias = [Double]($Miner_Profits_Bias.PSObject.Properties.Value | Measure -Sum).Sum
                $Miner.HashRates | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name | ForEach {
                    if(-not [String]$Miner.HashRates.$_)
                    {
                        $Miner_HashRates.$_ = $null
                        $Miner_Profits.$_ = $null
                        $Miner_Profits_Comparison.$_ = $null
                        $Miner_Profits_Bias.$_ = $null
                        $Miner_Profit = $null
                        $Miner_Profit_Comparison = $null
                        $Miner_Profit_Bias = $null
                    }
                }
                if($Miner_Types -eq $null){$Miner_Types = $Variables["Miners"].Type | Select -Unique}
                if($Miner_Indexes -eq $null){$Miner_Indexes = $Variables["Miners"].Index | Select -Unique}
                if($Miner_Types -eq $null){$Miner_Types = ""}
                if($Miner_Indexes -eq $null){$Miner_Indexes = 0}
                $Miner.HashRates = $Miner_HashRates
                $Miner | Add-Member Pools $Miner_Pools
                $Miner | Add-Member Profits $Miner_Profits
                $Miner | Add-Member Profits_Comparison $Miner_Profits_Comparison
                $Miner | Add-Member Profits_Bias $Miner_Profits_Bias
                $Miner | Add-Member Profit $Miner_Profit
                $Miner | Add-Member Profit_Comparison $Miner_Profit_Comparison
                $Miner | Add-Member Profit_Bias $Miner_Profit_Bias
                $Miner | Add-Member Profit_Bias_Orig $Miner_Profit_Bias
                $Miner | Add-Member Type $Miner_Types -Force
                $Miner | Add-Member Index $Miner_Indexes -Force
                # $Miner.Path = Convert-Path $Miner.Path

                $Miner_Devices = $Miner.Device | Select -Unique
                # if($Miner_Devices -eq $null){$Miner_Devices = (@($Variables["Miners"]).Where({(Compare $Miner.Type $_.Type -IncludeEqual -ExcludeDifferent | Measure).Count -gt 0})).Device | Select -Unique}
                if($Miner_Devices -eq $null){$Miner_Devices = $Miner.Type}
                $Miner | Add-Member Device $Miner_Devices -Force
                $Miner
            }).Where(
            {$Config.Type.Count -eq 0 -or (Compare $Config.Type $_.Type -IncludeEqual -ExcludeDifferent | Measure).Count -gt 0}).Where(
            {$Config.MinerName.Count -eq 0 -or (Compare $Config.MinerName $_.Name -IncludeEqual -ExcludeDifferent | Measure).Count -gt 0})
    }
    
    # 5.2.1
    # Added sceurity to filter miners with no user name in case of malformed miner or pool file
    $Variables["Miners"] = @($Variables["Miners"]).Where({$_.User})

    # 5.2.1
    # Exclude non benchmarked during donation.
    If ($Variables.DonationStart -or $Variables.DonationRunning) {
        $Variables["Miners"] = $Variables["Miners"].Where({$_.HashRates.Psobject.properties.value})
    }

    
        # Ban miners if too many failures as defined by MaxMinerFailure
        # 0 means no ban
        # Int value means ban after x failures
        # defaults to 3 if no value in config
        # ** Ban is not persistent across sessions **
       If ($Config.MaxMinerFailure -gt 0){
           $Config | Add-Member -Force @{ MaxMinerFailure = If ($Config.MaxMinerFailure) {$Config.MaxMinerFailure} else {3} }
           $BannedMiners = $Variables["ActiveMinerPrograms"].Where( { $_.Status -eq "Failed" -and $_.FailedCount -ge $Config.MaxMinerFailure } )
           # $BannedMiners | foreach { $Variables.StatusText = "BANNED: $($_.Name) / $($_.Algorithms). Too many failures. Consider Algo exclusion in config." }
           $BannedMiners | foreach { "BANNED: $($_.Name) / $($_.Algorithms). Too many failures. Consider Algo exclusion in config." | Out-Host }
           $Variables["Miners"] = $Variables["Miners"].Where( { -not ($_.Path -in $BannedMiners.Path -and $_.Arguments -in $BannedMiners.Arguments) } )
       }


        @($Variables["Miners"] | Sort Path,URI -Unique).Where({ (Test-Path $_.Path) -eq $false }) | ForEach {
            $Miner = $_
            if((Test-Path $Miner.Path) -eq $false)
            {
                $Variables.StatusText = "Downloading $($Miner.Name).."
                if((Split-Path $Miner.URI -Leaf) -eq (Split-Path $Miner.Path -Leaf))
                {
                    New-Item (Split-Path $Miner.Path) -ItemType "Directory" | Out-Null
                    Invoke-WebRequest $Miner.URI -UseBasicParsing -TimeoutSec 15 -OutFile $_.Path
                }
                elseif(([IO.FileInfo](Split-Path $_.URI -Leaf)).Extension -eq '')
                {
                    $Path_Old = Get-PSDrive -PSProvider FileSystem | ForEach {Get-ChildItem -Path $_.Root -Include (Split-Path $Miner.Path -Leaf) -Recurse -ErrorAction Ignore} | Sort LastWriteTimeUtc -Descending | Select -First 1
                    $Path_New = $Miner.Path

                    if($Path_Old -ne $null)
                    {
                        if(Test-Path (Split-Path $Path_New)){(Split-Path $Path_New) | Remove-Item -Recurse -Force}
                        (Split-Path $Path_Old) | Copy-Item -Destination (Split-Path $Path_New) -Recurse -Force
                    }
                    else
                    {
                        $Variables.StatusText = "Cannot find $($Miner.Path) distributed at $($Miner.URI). "
                    }
                }
                else
                {
                    Expand-WebRequest $Miner.URI (Split-Path $Miner.Path)
                }
            }
            else
            {
                $Miner
            }
        }


    $Variables["Miners"] = $Variables["Miners"].Where({ (Test-Path $_.Path) -eq $true })

        # If (! $Variables.DonationRunning) {
            $Variables.StatusText = "Comparing miners and pools.."
            if($Variables["Miners"].Count -eq 0){$Variables.StatusText = "No Miners!"}#; sleep $Config.Interval; continue}

            # Remove miners when no estimation info from pools or 0BTC. Avoids mining when algo down at pool or benchmarking for ever
            If (($Variables["Miners"] | ? {($_.Pools.PSObject.Properties.Value.Price -ne $null) -and ($_.Pools.PSObject.Properties.Value.Price -gt 0)}).Count -gt 0) {$Variables["Miners"] = $Variables["Miners"] | ? {($_.Pools.PSObject.Properties.Value.Price -ne $null) -and ($_.Pools.PSObject.Properties.Value.Price -gt 0)}}
            #Don't penalize active miners. Miner could switch a little bit later and we will restore his bias in this case
            $Variables["ActiveMinerPrograms"] | Where { $_.Status -eq "Running" } | ForEach {$Variables["Miners"] | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments | ForEach {$_.Profit_Bias = $_.Profit * (1 + $Config.ActiveMinerGainPct / 100)}}
            #Get most profitable miner combination i.e. AMD+NVIDIA+CPU
            $BestMiners = $Variables["Miners"] | Select Type,Index -Unique | ForEach {$Miner_GPU = $_; ($Variables["Miners"] | Where {(Compare $Miner_GPU.Type $_.Type | Measure).Count -eq 0 -and (Compare $Miner_GPU.Index $_.Index | Measure).Count -eq 0} | Sort -Descending {($_ | Where Profit -EQ $null | Measure).Count},{($_ | Measure Profit_Bias -Sum).Sum},{($_ | Where Profit -NE 0 | Measure).Count} | Select -First 1)}
            $BestDeviceMiners = $Variables["Miners"] | Select Device -Unique | ForEach {$Miner_GPU = $_; ($Variables["Miners"] | Where {(Compare $Miner_GPU.Device $_.Device | Measure).Count -eq 0} | Sort -Descending {($_ | Where Profit -EQ $null | Measure).Count},{($_ | Measure Profit_Bias -Sum).Sum},{($_ | Where Profit -NE 0 | Measure).Count} | Select -First 1)}
            $BestMiners_Comparison = $Variables["Miners"] | Select Type,Index -Unique | ForEach {$Miner_GPU = $_; ($Variables["Miners"] | Where {(Compare $Miner_GPU.Type $_.Type | Measure).Count -eq 0 -and (Compare $Miner_GPU.Index $_.Index | Measure).Count -eq 0} | Sort -Descending {($_ | Where Profit -EQ $null | Measure).Count},{($_ | Measure Profit_Comparison -Sum).Sum},{($_ | Where Profit -NE 0 | Measure).Count} | Select -First 1)}
            $BestDeviceMiners_Comparison = $Variables["Miners"] | Select Device -Unique | ForEach {$Miner_GPU = $_; ($Variables["Miners"] | Where {(Compare $Miner_GPU.Device $_.Device | Measure).Count -eq 0} | Sort -Descending {($_ | Where Profit -EQ $null | Measure).Count},{($_ | Measure Profit_Comparison -Sum).Sum},{($_ | Where Profit -NE 0 | Measure).Count} | Select -First 1)}
            $Miners_Type_Combos = @([PSCustomObject]@{Combination = @()}) + (Get-Combination ($Variables["Miners"] | Select Type -Unique) | Where{(Compare ($_.Combination | Select -ExpandProperty Type -Unique) ($_.Combination | Select -ExpandProperty Type) | Measure).Count -eq 0})
            $Miners_Index_Combos = @([PSCustomObject]@{Combination = @()}) + (Get-Combination ($Variables["Miners"] | Select Index -Unique) | Where{(Compare ($_.Combination | Select -ExpandProperty Index -Unique) ($_.Combination | Select -ExpandProperty Index) | Measure).Count -eq 0})
            $Miners_Device_Combos = (Get-Combination ($Variables["Miners"] | Select Device -Unique) | Where{(Compare ($_.Combination | Select -ExpandProperty Device -Unique) ($_.Combination | Select -ExpandProperty Device) | Measure).Count -eq 0})
            $BestMiners_Combos = $Miners_Type_Combos | ForEach {$Miner_Type_Combo = $_.Combination; $Miners_Index_Combos | ForEach {$Miner_Index_Combo = $_.Combination; [PSCustomObject]@{Combination = $Miner_Type_Combo | ForEach {$Miner_Type_Count = $_.Type.Count; [Regex]$Miner_Type_Regex = '^(' + (($_.Type | ForEach {[Regex]::Escape($_)}) -join '|') + ')$'; $Miner_Index_Combo | ForEach {$Miner_Index_Count = $_.Index.Count; [Regex]$Miner_Index_Regex = '^(' + (($_.Index | ForEach {[Regex]::Escape($_)}) -join '|') + ')$'; $BestMiners | Where {([Array]$_.Type -notmatch $Miner_Type_Regex).Count -eq 0 -and ([Array]$_.Index -notmatch $Miner_Index_Regex).Count -eq 0 -and ([Array]$_.Type -match $Miner_Type_Regex).Count -eq $Miner_Type_Count -and ([Array]$_.Index -match $Miner_Index_Regex).Count -eq $Miner_Index_Count}}}}}}
            $BestMiners_Combos += $Miners_Device_Combos | ForEach {$Miner_Device_Combo = $_.Combination; [PSCustomObject]@{Combination = $Miner_Device_Combo | ForEach {$Miner_Device_Count = $_.Device.Count; [Regex]$Miner_Device_Regex = '^(' + (($_.Device | ForEach {[Regex]::Escape($_)}) -join '|') + ')$'; $BestDeviceMiners | Where {([Array]$_.Device -notmatch $Miner_Device_Regex).Count -eq 0 -and ([Array]$_.Device -match $Miner_Device_Regex).Count -eq $Miner_Device_Count}}}}
            $BestMiners_Combos_Comparison = $Miners_Type_Combos | ForEach {$Miner_Type_Combo = $_.Combination; $Miners_Index_Combos | ForEach {$Miner_Index_Combo = $_.Combination; [PSCustomObject]@{Combination = $Miner_Type_Combo | ForEach {$Miner_Type_Count = $_.Type.Count; [Regex]$Miner_Type_Regex = '^(' + (($_.Type | ForEach {[Regex]::Escape($_)}) -join '|') + ')$'; $Miner_Index_Combo | ForEach {$Miner_Index_Count = $_.Index.Count; [Regex]$Miner_Index_Regex = '^(' + (($_.Index | ForEach {[Regex]::Escape($_)}) -join '|') + ')$'; $BestMiners_Comparison | Where {([Array]$_.Type -notmatch $Miner_Type_Regex).Count -eq 0 -and ([Array]$_.Index -notmatch $Miner_Index_Regex).Count -eq 0 -and ([Array]$_.Type -match $Miner_Type_Regex).Count -eq $Miner_Type_Count -and ([Array]$_.Index -match $Miner_Index_Regex).Count -eq $Miner_Index_Count}}}}}}
            $BestMiners_Combos_Comparison += $Miners_Device_Combos | ForEach {$Miner_Device_Combo = $_.Combination; [PSCustomObject]@{Combination = $Miner_Device_Combo | ForEach {$Miner_Device_Count = $_.Device.Count; [Regex]$Miner_Device_Regex = '^(' + (($_.Device | ForEach {[Regex]::Escape($_)}) -join '|') + ')$'; $BestDeviceMiners_Comparison | Where {([Array]$_.Device -notmatch $Miner_Device_Regex).Count -eq 0 -and ([Array]$_.Device -match $Miner_Device_Regex).Count -eq $Miner_Device_Count}}}}
            $BestMiners_Combo = $BestMiners_Combos | Sort -Descending {($_.Combination | Where Profit -EQ $null | Measure).Count},{($_.Combination | Measure Profit_Bias -Sum).Sum},{($_.Combination | Where Profit -NE 0 | Measure).Count} | Select -First 1 | Select -ExpandProperty Combination
            $BestMiners_Combo_Comparison = $BestMiners_Combos_Comparison | Sort -Descending {($_.Combination | Where Profit -EQ $null | Measure).Count},{($_.Combination | Measure Profit_Comparison -Sum).Sum},{($_.Combination | Where Profit -NE 0 | Measure).Count} | Select -First 1 | Select -ExpandProperty Combination
            # No CPU mining if GPU miner prevents it
            If ($BestMiners_Combo.PreventCPUMining -contains $true) {
                $BestMiners_Combo = $BestMiners_Combo | ? {$_.type -ne "CPU"}
                $Variables.StatusText = "Miner prevents CPU mining"
            }
        # }
        
        # Prevent switching during donation
        If ($Variables.DonationStart -or $Variables.DonationRunning) {
            If ($Variables.DonationRunning) {$BestMiners_Combo = $Variables.DonationBestMiners_Combo}
            If ($Variables.DonationStart) {
                $BestMiners_Combo | % {
                    $_.Arguments = $_.Arguments -replace "$($Config.PoolsConfig.Default.WorkerName)","$($Config.PoolsConfig.Default.WorkerName)_$($_.Type)"
                    $_.Pools.PSObject.Properties.Value | ForEach {$_.Name = "DevFee"}
                }
                $Variables.DonationBestMiners_Combo = $BestMiners_Combo 
            }
        }

        $Variables.StatusText = "Assigning miners.."
        
        #Add the most profitable miners to the active list
        # Prevent switching during donation
        # If (! $Variables.DonationRunning -or ($Variables["ActiveMinerPrograms"] | ? {$_.Status -ne "Idle" -and ($_.Process -eq $null -or $_.Process.HasExited -ne $false})).Count -gt 0) {
        # If (! $Variables.DonationRunning) {
            $BestMiners_Combo | ForEach {
                if(($Variables["ActiveMinerPrograms"] | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments).Count -eq 0)
                {
                    $Variables["ActiveMinerPrograms"] += [PSCustomObject]@{
                        Type = $_.Type
                        Name = $_.Name
                        Path = $_.Path
                        Arguments = $_.Arguments
                        Wrap = $_.Wrap
                        Process = $null
                        API = $_.API
                        Port = $_.Port
                        Algorithms = $_.HashRates.PSObject.Properties.Name
                        New = $false
                        Active = [TimeSpan]0
                        TotalActive = [TimeSpan]0
                        Activated = 0
                        FailedCount = 0
                        Status = "Idle"
                        HashRate = 0
                        Benchmarked = 0
                        Hashrate_Gathered = ($_.HashRates.PSObject.Properties.Value -ne $null)
                        User = $_.User
                        Host = $_.Host
                        Coin = $_.Coin
                        Pools = $_.Pools
                        ThreadCount = $_.ThreadCount
                    }
                }
            }
            #Stop or start miners in the active list depending on if they are the most profitable
            # We have to stop processes first or the port would be busy
            $Variables["ActiveMinerPrograms"] | ForEach {
                [Array]$filtered = ($BestMiners_Combo | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments)
                if($filtered.Count -eq 0)
                {
                    if($_.Process -eq $null)
                    {
                        $_.Status = "Failed"
                        $_.FailedCount++
                    }
                    elseif ($_.Process.HasExited -eq $false) {
                        $_.Process.CloseMainWindow() | Out-Null
                        Sleep 1
                        # simply "Kill with power"
                        Stop-Process $_.Process -Force | Out-Null
                        # Try to kill any process with the same path, in case it is still running but the process handle is incorrect
                        $KillPath = $_.Path
                        Get-Process | Where-Object {$_.Path -eq $KillPath} | Stop-Process -Force
                        Write-Host -ForegroundColor Yellow "closing miner"
                        Sleep 1
                        $_.Status = "Idle"
                    }
                    #Restore Bias for non-active miners
                    $Variables["Miners"] | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments | ForEach {$_.Profit_Bias = $_.Profit_Bias_Orig}
                }
            }
            $newMiner = $false
            $CurrentMinerHashrate_Gathered =$false 
            $newMiner = $false
            $CurrentMinerHashrate_Gathered =$false 
            $Variables["ActiveMinerPrograms"] | ForEach {
                [Array]$filtered = ($BestMiners_Combo | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments)
                if($filtered.Count -gt 0)
                {
                    if($_.Process -eq $null -or $_.Process.HasExited -ne $false)
                    {
                        # Migrate previous version of .\log\switching.log (Add Coin)
                        # Move to app init
                        If (Test-Path ".\Logs\switching.log") {
                            If (!(Get-Content ".\Logs\switching.log" -First 1).Contains("coin")) {
                                $tmp = @()
                                Import-Csv .\Logs\switching.log | % {$tmp += [PsCustomObject][Ordered]@{date=$_.date;Type=$_.Type;algo=$_.Algo;coin=$_.Coin;wallet=$_.wallet;username=$_.UserName;Host=$_.host}}
                                $tmp | export-csv .\Logs\switching.log -NoTypeInformation -Force
                                rv tmp
                            }
                        }
                        # Log switching information to .\log\switching.log
                        [pscustomobject]@{date=(get-date);Type=$_.Type;algo=$_.Algorithms -join ',';coin=$_.Coin -join ',';wallet=$_.User -join ',';username=$Config.UserName -join ',';Host=$_.host -join ','} | export-csv .\Logs\switching.log -Append -NoTypeInformation -Force
                        If ($Variables.DonationStart) {
                            $Variables.DonationStart = $False 
                            $Variables.DonationRunning = $True 
                        }

                        # Launch prerun if exists
                        If ($_.Type -eq "AMD" -and (Test-Path ".\Prerun\AMDPrerun.bat")) {
                            Start-Process ".\Prerun\AMDPrerun.bat" -WorkingDirectory ".\Prerun" -WindowStyle hidden
                        }
                        If ($_.Type -eq "NVIDIA" -and (Test-Path ".\Prerun\NVIDIAPrerun.bat")) {
                            Start-Process ".\Prerun\NVIDIAPrerun.bat" -WorkingDirectory ".\Prerun" -WindowStyle hidden
                        }
                        If ($_.Type -eq "CPU" -and (Test-Path ".\Prerun\CPUPrerun.bat")) {
                            Start-Process ".\Prerun\CPUPrerun.bat" -WorkingDirectory ".\Prerun" -WindowStyle hidden
                        }
                        If ($_.Type -ne "CPU") {
                            $PrerunName = ".\Prerun\"+$_.Algorithms+".bat"
                            $DefaultPrerunName = ".\Prerun\default.bat"
                                    If (Test-Path $PrerunName) {
                                $Variables.StatusText = "Launching Prerun: $PrerunName"
                                Start-Process $PrerunName -WorkingDirectory ".\Prerun" -WindowStyle hidden
                                Sleep 2
                            } else {
                                If (Test-Path $DefaultPrerunName) {
                                    $Variables.StatusText = "Launching Prerun: $DefaultPrerunName"
                                    Start-Process $DefaultPrerunName -WorkingDirectory ".\Prerun" -WindowStyle hidden
                                    Sleep 2
                                    }
                            }
                        }

                        Sleep $Config.Delay #Wait to prevent BSOD
                        $Variables.StatusText = "Starting miner"
                        $Variables.DecayStart = Get-Date
                        $_.New = $true
                        $_.Activated++
                        # if($_.Process -ne $null){$_.TotalActive += $_.Process.ExitTime-$_.Process.StartTime}
                        if($_.Process -ne $null){$_.Active = [TimeSpan]0}
                        
                        # if($_.Wrap){$_.Process = Start-Process -FilePath "PowerShell" -ArgumentList "-executionpolicy bypass -command . '$(Convert-Path ".\Includes\Wrapper.ps1")' -ControllerProcessID $PID -Id '$($_.Port)' -FilePath '$($_.Path)' -ArgumentList '$($_.Arguments)' -WorkingDirectory '$(Split-Path $_.Path)'" -PassThru}
                        if($_.Wrap){$_.Process = Start-Process -FilePath "PowerShell" -ArgumentList "-executionpolicy bypass -command . '$(Convert-Path ".\Includes\Wrapper.ps1")' -ControllerProcessID $PID -Id '$($_.Port)' -FilePath '$($_.Path)' -ArgumentList '$($_.Arguments)' -WorkingDirectory '$($Variables.MainPath)'" -PassThru}
                        else{$_.Process = Start-SubProcess -FilePath $_.Path -ArgumentList $_.Arguments -WorkingDirectory (Split-Path $_.Path) -ThreadCount $_.ThreadCount}
                        if($_.Process -eq $null){$_.Status = "Failed";$_.FailedCount++}
                        else {
                            $_.Status = "Running"
                            $newMiner = $true
							If ($_.Type -eq "CPU" -and $Config.UseLowPriorityForCPUMiners) {
								$_.Process.PriorityClass = 16384
							}
                            #Newely started miner should looks better than other in the first run too
                            $Variables["Miners"] | Where Path -EQ $_.Path | Where Arguments -EQ $_.Arguments | ForEach {$_.Profit_Bias = $_.Profit * (1 + $Config.ActiveMinerGainPct / 100)}
                        }
                    } else {
                        $now = Get-Date
                        $_.TotalActive = $_.TotalActive + ( $Now - $_.Process.StartTime ) - $_.Active
                        $_.Active = $Now - $_.Process.StartTime
                    }
                    $CurrentMinerHashrate_Gathered = $_.Hashrate_Gathered
                }
            }
        # }
        #Do nothing for a few seconds as to not overload the APIs
        if ($newMiner -eq $true) {
            # if ($Config.Interval -ge $Config.FirstInterval -and $Config.Interval -ge $Config.StatsInterval) { $Variables.TimeToSleep = $Config.Interval }
            # else {
                if ($CurrentMinerHashrate_Gathered -eq $true) { $Variables.TimeToSleep = $Config.FirstInterval }
                else { $Variables.TimeToSleep =  $Config.StatsInterval }
            # }
        } else {
            $Variables.TimeToSleep = $Config.Interval
        }
        "--------------------------------------------------------------------------------" | out-host
        #Do nothing for a few seconds as to not overload the APIs
        if ($newMiner -eq $true) {
            # if ($Config.Interval -ge $Config.FirstInterval -and $Config.Interval -ge $Config.StatsInterval) { $Variables.TimeToSleep = $Config.Interval }
            # else {
                if ($CurrentMinerHashrate_Gathered -eq $true) { $Variables.TimeToSleep = $Config.FirstInterval }
                else { $Variables.TimeToSleep =  $Config.StatsInterval }
            # }
        } else {
        $Variables.TimeToSleep = $Config.Interval
        }
        # Prevent switching during donation
        # If ( $Variables.DonationRunning ) { If ($Config.Interval -ge ($Config.Donate * 60)) {$Variables.TimeToSleep = $Config.Interval} else {$Variables.TimeToSleep = $Config.Donate * 60 }}
        #Save current hash rates
        $Variables["ActiveMinerPrograms"] | ForEach {
            if($_.Process -eq $null -or $_.Process.HasExited)
            {
                if($_.Status -eq "Running"){$_.Status = "Failed";$_.FailedCount++}
            }
            else
            {
                # we don't want to store hashrates if we run less than $Config.StatsInterval sec
                $WasActive = [math]::Round(((Get-Date)-$_.Process.StartTime).TotalSeconds)
                if ($WasActive -ge $Config.StatsInterval) {
                    $_.HashRate = 0
                    $Miner_HashRates = $null
                    if($_.New){$_.Benchmarked++}         
                    $Miner_HashRates = Get-HashRate $_.API $_.Port ($_.New -and $_.Benchmarked -lt 3)
                    $_.HashRate = $Miner_HashRates | Select -First $_.Algorithms.Count           
                    if($Miner_HashRates.Count -ge $_.Algorithms.Count)
                    {
                        for($i = 0; $i -lt $_.Algorithms.Count; $i++)
                        {
                            $Stat = Set-Stat -Name "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate" -Value ($Miner_HashRates | Select -Index $i)
                        }
                        $_.New = $false
                        $_.Hashrate_Gathered = $true
                        "Stats $($_.Algorithms) -> $($Miner_HashRates | ConvertTo-Hash) after $($WasActive) sec" | out-host
                    }
                }
            }
            
            # Benchmark timeout
           # if($_.Benchmarked -ge 6 -or ($_.Benchmarked -ge 3 -and $_.Activated -ge 3))
           # {
               # for($i = 0; $i -lt $_.Algorithms.Count; $i++)
               # {
                   # if((Get-Stat "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate") -eq $null)
                   # {
                       # $Stat = Set-Stat -Name "$($_.Name)_$($_.Algorithms | Select -Index $i)_HashRate" -Value 0
                   # }
               # }
           # }
        }
    # }

    <#
     For some reason (need to investigate) $Variables["ActiveMinerPrograms"].psobject.TypeNames
     Inflates adding several lines at each loop and causing a memory leak after log runtime
     Code below copies the object which results in a new version which avoid the problem.
     Will need rework. 
    #>
    $Variables["ActiveMinerPrograms"] | Where {$_.Status -ne "Running"} | foreach {$_.process = $_.process | select HasExited,StartTime,ExitTime}
    $ActiveMinerProgramsCOPY = [System.Collections.ArrayList]::Synchronized(@())
    $Variables["ActiveMinerPrograms"] | %{$ActiveMinerCOPY = [PSCustomObject]@{}; $_.psobject.properties | sort Name | %{$ActiveMinerCOPY | Add-Member -Force @{$_.Name = $_.Value}};$ActiveMinerProgramsCOPY += $ActiveMinerCOPY}
    $Variables["ActiveMinerPrograms"] = $ActiveMinerProgramsCOPY
    rv ActiveMinerProgramsCOPY
    rv ActiveMinerCOPY
    
    $Error.Clear()
    $Global:Error.clear()
    
    Get-Job | ? {$_.State -eq "Completed"} | Remove-Job
    if ($Variables.BrainJobs.count -gt 0){
        $Variables.BrainJobs | % {$_.ChildJobs | % {$_.Error.Clear()}}
        $Variables.BrainJobs | % {$_.ChildJobs | % {$_.Progress.Clear()}}
        $Variables.BrainJobs.ChildJobs | % {$_.Output.Clear()}
    }
    if ($Variables.EarningsTrackerJobs.count -gt 0) {
        $Variables.EarningsTrackerJobs | % {$_.ChildJobs | % {$_.Error.Clear()}}
        $Variables.EarningsTrackerJobs | % {$_.ChildJobs | % {$_.Progress.Clear()}}
        $Variables.EarningsTrackerJobs.ChildJobs | % {$_.Output.Clear()}
    }

    # Mostly used for debug. Will execute code found in .\EndLoopCode.ps1 if exists.
    if (Test-Path ".\EndLoopCode.ps1"){Invoke-Expression (Get-Content ".\EndLoopCode.ps1" -Raw)}
}

    $CycleTime = Measure-Command -Expression $CycleScriptBlock.Ast.GetScriptBlock()

    # $Variables.StatusText = "Cycle Time (seconds): $($CycleTime.TotalSeconds)"
    "$((Get-Date).ToString()) - Cycle Time (seconds): $($CycleTime.TotalSeconds)" | out-host
    If ($variables.DonationRunning) {
        $Variables.StatusText = "Waiting $($Variables.TimeToSleep) seconds... | Next refresh: $((Get-Date).AddSeconds($Variables.TimeToSleep)) | Donation running. Thanks for your support!"
    } else {
        $Variables.StatusText = "Waiting $($Variables.TimeToSleep) seconds... | Next refresh: $((Get-Date).AddSeconds($Variables.TimeToSleep))"
        $Variables.StatusText = "!! Check out the new server features and remote management web interface !!"
    }
    $Variables.EndLoop = $True
    # Sleep $Variables.TimeToSleep
    # }
# $Variables.BrainJobs | foreach { $_ | stop-job | remove-job }
# $Variables.BrainJobs = @()
# $pid | out-host
# $Variables | convertto-json | out-file ".\logs\variables.json"
# Remove-Variable Stats,Miners_Type_Combos,Miners_Index_Combos,Miners_Device_Combos,BestMiners_Combos,BestMiners_Combos_Comparison,AllPools,Pools,Miner_Pools,Miner_Pools_Comparison,Miner_Profits,Miner_Profits_Comparison,Miner_Profits_Bias,Miner
# Get-Variable | out-file ".\logs\variables.txt"
# $StackTrace | convertto-json | out-file ".\logs\stacktrace.json"
# remove-variable variables
# Get-MemoryUsage
}
#Stop the log
# Stop-Transcript

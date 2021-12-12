if (!(IsLoaded(".\Includes\include.ps1"))) {. .\Includes\include.ps1; RegisterLoaded(".\Includes\include.ps1")}
 
$Path = ".\Bin\NVIDIA-AMD-lolMiner\lolMiner.exe"
# $Uri = "https://github.com/Lolliedieb/lolMiner-releases/releases/download/0.96/lolMiner_v0961_Win64.zip"
$Uri = "https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.17/lolMiner_v1.17_Win64.zip"

$Commands = [PSCustomObject]@{
    # "equihash96" = " --coin MNX" #Equihash 96,5
    "Equihash21x9" = "--coin AION" #Equihash 210,9
    "equihash144" = " --coin AUTO144_5" #Equihash 144,5
    "equihash192x7" = " --coin AUTO192_7"
    "equihash144x5" = " --coin BTCZ"
    "equihash144x5I = " --coin BTG"
    "GrinCuckatoo32" = " --coin GRIN-C32" #Equihash 144,5
    "beam" = " --coin BEAM" #Equihash 150,5
    "cortex" = " --coin CTXC"
    "ethash" = " --coin ETH"
    "etchash" = " --coin ETC"
    "grinc29" = " --coin GRIN-C29M"
    "grinc32" = " --coin GRIN-C32"
    "mwcc29d" =" --coin MWC-C29D"
    "mwcc31" =" --coin MWC-C31"
    "equihash144x5ii" =" --coin XSG"
    "zelhash" =" --coin ZEL
    }
$Name = (Get-Item $script:MyInvocation.MyCommand.Path).BaseName
$WinningCustomConfig = [PSCustomObject]@{}

$Commands | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {
    $fee = switch ($_){
        "octopus"   {0.02}
        "etchash"   {0.007}  
        "ethash"    {0.007}
        "cortex"    {0.025}
        default     {0.01}
    }
    
    $Algo =$_
    $AlgoNorm = Get-Algorithm($_)

    $Pools.($AlgoNorm) | foreach {
        $Pool = $_
        invoke-Expression -command ( $MinerCustomConfigCode )
        If ($AbortCurrentPool) {Return}

        $Arguments = "--user $($Pool.User) --pool $($Pool.Host) --port $($Pool.Port) --devices $($Config.SelGPUCC) --apiport $($Variables.NVIDIAMinerAPITCPPort) --tls 0 --digits 2 --longstats 60 --shortstats 5 --connectattempts 3 --pass $($Password)"
        [PSCustomObject]@{
            Type      = "NVIDIA"
            Path      = $Path
            Arguments =  Merge-Command -Slave $Arguments -Master $CustomCmdAdds -Type "Command"
            HashRates = [PSCustomObject]@{($Algo) = $Stats."$($Name)_$($Algo)_HashRate".Week * (1-$fee) # 1% dev fee
            API       = "LOL"
            Port      = $Variables.NVIDIAMinerAPITCPPort
            Wrap      = $false
            URI       = $Uri    
            User = $Pool.User
            Host = $Pool.Host
            Coin = $Pool.Coin
        }
        
        $Arguments = "--user $($Pool.User) --pool $($Pool.Host) --port $($Pool.Port) --devices $($Config.SelGPUCC) --apiport $($Variables.AMDMinerAPITCPPort) --tls 0 --digits 2 --longstats 60 --shortstats 5 --connectattempts 3 --pass $($Password)"
        [PSCustomObject]@{
            Type      = "AMD"
            Path      = $Path
            Arguments =  Merge-Command -Slave $Arguments -Master $CustomCmdAdds -Type "Command"
            HashRates = [PSCustomObject]@{($Algo) = $Stats."$($Name)_$($Algo)_HashRate".Week *(1-$fee)} # dev fee
            API       = "LOL"
            Port      = $Variables.AMDMinerAPITCPPort
            Wrap      = $false
            URI       = $Uri    
            User = $Pool.User
            Host = $Pool.Host
            Coin = $Pool.Coin
        }
    }
}



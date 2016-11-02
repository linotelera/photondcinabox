# requires posh-ssh
# requires docker
# requires docker-machine


# Ask for data
$sMachineName = "";
$sHost="";
$sUser="";
$sPassword="";

# TODO Ask for alias fqdn -> array
$sDirDocker = "$HOME\.docker\machine\machines";
$sDirUserRootDocker = "$HOME\.docker\machine";
$sHostCertDir = "/opt/docker/certs";
$sDokerDaemonConfig = "/lib/systemd/system/docker.service";
$sScriptPath = split-path -parent $MyInvocation.MyCommand.Definition;
$sCurrentDir = (Get-Item -Path ".\" -Verbose).FullName
$sDoubleSlashPath = $sDirUserRootDocker.Replace('\','\\');



function createDockerMachine{
    param (
           [string]$sHost,
           [string]$sMachineName
     )
    
   

    $sHostPort = $sHost+":2376"
    echo $sHostPort
    echo "[client] Creates docker-machine tcp://$sHostPort $sMachineName"
    docker-machine.exe create -d none --url tcp://$sHostPort $sMachineName
    
}

function generateServerCerts{
    param (
           [string]$sHost,
           [string]$sHostCertDir,
           [string]$sUser,
           [string]$sPassword
     )
    echo "Access to host $sHost";
    #$oCredential = Get-Credential
    $secpasswd = ConvertTo-SecureString $sPassword -AsPlainText -Force
    $oCredential = New-Object System.Management.Automation.PSCredential ($sUser, $secpasswd)

    $oSessionSSH = New-SSHSession -ComputerName $sHost -Credential $oCredential
    

    echo "[host] Make directories"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "mkdir -p $sHostCertDir"

    #TODO Check if prev certs exists

    echo "[host] Generate server certificate"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl genrsa -passout pass:passwd -aes256 -out $sHostCertDir/ca-key.pem 4096"


    # Check if certificate exists -> skip
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl req -passin pass:passwd -new -x509 -days 365 -key $sHostCertDir/ca-key.pem -sha256 -out $sHostCertDir/ca.pem -subj `"/C=IT/ST=Italy/L=Cremona/O=RD/OU=RD/CN=$sHost`""
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl genrsa -passout pass:passwd -out $sHostCertDir/server-key.pem 4096"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl req -passout pass:passwd -subj `"/CN=$sHost`" -sha256 -new -key $sHostCertDir/server-key.pem -out $sHostCertDir/server.csr"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "echo `"subjectAltName = IP:$sHost,IP:127.0.0.1`" > $sHostCertDir/extfile.cnf"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl x509 -req -passin pass:passwd -days 365 -sha256 -in $sHostCertDir/server.csr -CA $sHostCertDir/ca.pem -CAkey $sHostCertDir/ca-key.pem -CAcreateserial -out $sHostCertDir/server-cert.pem -extfile $sHostCertDir/extfile.cnf"


    echo "Close/Remove Sessions"
    Remove-SSHSession -SSHSession $oSessionSSH
}

function setUpRemoteDockerHost{
    param (
           [string]$sHost,
           [string]$sHostCertDir,
           [string]$sUser,
           [string]$sPassword
     )
    echo "Access to host $sHost";
    #$oCredential = Get-Credential
    $secpasswd = ConvertTo-SecureString $sPassword -AsPlainText -Force
    $oCredential = New-Object System.Management.Automation.PSCredential ($sUser, $secpasswd)

    $oSessionSSH = New-SSHSession -ComputerName $sHost -Credential $oCredential
    $oSessionSFTP = New-SFTPSession -ComputerName $sHost -Credential $oCredential


    # Check if certificate exists -> skip
    echo "[host] Generate client certificate 1-only cert"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl genrsa -passout pass:passwd -out $sHostCertDir/client-key.pem 4096"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl req -passout pass:passwd -subj '/CN=client' -new -key $sHostCertDir/client-key.pem -out $sHostCertDir/client.csr"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "echo `"extendedKeyUsage = clientAuth`" > $sHostCertDir/extfile2.cnf"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "openssl x509 -req -passin pass:passwd -days 365 -sha256 -in $sHostCertDir/client.csr -CA $sHostCertDir/ca.pem -CAkey $sHostCertDir/ca-key.pem -CAcreateserial -out $sHostCertDir/client-cert.pem -extfile $sHostCertDir/extfile2.cnf"

    echo " [host] change exec docker-machine with certificates"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "sed -i `"/ExecStart=/c\ExecStart=/usr/bin/docker daemon --tls=true --tlscert=$sHostCertDir/server-cert.pem --tlskey=$sHostCertDir/server-key.pem -H tcp://0.0.0.0:2376 --containerd /run/containerd.sock -H unix:///var/run/docker.sock --tlsverify=true --tlscacert=$sHostCertDir/ca.pem`" $sDokerDaemonConfig"

    echo "[host] Restart docker"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "systemctl daemon-reload && systemctl restart docker"

    echo "[host] Configure port firewall"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "iptables -D INPUT -p tcp --dport 2376 -j ACCEPT"
    $command = Invoke-SSHCommand -SSHSession $oSessionSSH "iptables -I INPUT -p tcp --dport 2376 -j ACCEPT"

    echo "Close/Remove Sessions"
    Remove-SSHSession -SSHSession $oSessionSSH

}


function getMainClientCerts{

    param (
           [string]$sHost,
           [string]$sUser,
           [string]$sPassword,
           [string]$sDirDocker,
           [string]$sMachineName,
           [string]$sHostCertDir
     )

    echo "Access to host $sHost";
    #$oCredential = Get-Credential
    $secpasswd = ConvertTo-SecureString $sPassword -AsPlainText -Force
    $oCredential = New-Object System.Management.Automation.PSCredential ($sUser, $secpasswd)
    $oSessionSFTP = New-SFTPSession -ComputerName $sHost -Credential $oCredential

    echo "[client] get client certificate and put certificate in docker/user directory"

    Get-SFTPFile -SFTPSession $oSessionSFTP -RemoteFile "$sHostCertDir/client-cert.pem" -LocalPath "$sDirDocker/$sMachineName/" -Overwrite
    Get-SFTPFile -SFTPSession $oSessionSFTP -RemoteFile "$sHostCertDir/client-key.pem" -LocalPath "$sDirDocker/$sMachineName/" -Overwrite

    Get-SFTPFile -SFTPSession $oSessionSFTP -RemoteFile "$sHostCertDir/ca.pem" -LocalPath "$sDirDocker/$sMachineName/" -Overwrite
    Get-SFTPFile -SFTPSession $oSessionSFTP -RemoteFile "$sHostCertDir/ca-key.pem" -LocalPath "$sDirDocker/$sMachineName/" -Overwrite

    Get-SFTPFile -SFTPSession $oSessionSFTP -RemoteFile "$sHostCertDir/server-cert.pem" -LocalPath "$sDirDocker/$sMachineName/" -Overwrite
    Get-SFTPFile -SFTPSession $oSessionSFTP -RemoteFile "$sHostCertDir/server-key.pem" -LocalPath "$sDirDocker/$sMachineName/" -Overwrite

    Rename-Item $sDirDocker/$sMachineName/client-cert.pem cert.pem -Force
    Rename-Item $sDirDocker/$sMachineName/client-key.pem key.pem -Force

    echo "Close/Remove Sessions"
    Remove-SFTPSession -SFTPSession $oSessionSFTP

}



function changeClientDockerMachine{

    param (
           [string]$sDirDocker,
           [string]$sMachineName,
           [string]$sDoubleSlashPath
          
     )


    echo "[client] Modify config.json file"

    (Get-Content $sDirDocker/$sMachineName/config.json).replace("`"CertDir`": `"$sDoubleSlashPath\\certs`",", "`"CertDir`": `"$sDoubleSlashPath\\machines\\$sMachineName`",") | Set-Content $sDirDocker/$sMachineName/config.json
    (Get-Content $sDirDocker/$sMachineName/config.json).replace("`"CaCertPath`": `"$sDoubleSlashPath\\certs\\ca.pem`",", "`"CaCertPath`": `"$sDoubleSlashPath\\machines\\$sMachineName\\ca.pem`",") | Set-Content $sDirDocker/$sMachineName/config.json
    (Get-Content $sDirDocker/$sMachineName/config.json).replace("`"CaPrivateKeyPath`": `"$sDoubleSlashPath\\certs\\ca-key.pem`",", "`"CaPrivateKeyPath`": `"$sDoubleSlashPath\\machines\\$sMachineName\\ca-key.pem`",") | Set-Content $sDirDocker/$sMachineName/config.json

    (Get-Content $sDirDocker/$sMachineName/config.json).replace("`"ClientKeyPath`": `"$sDoubleSlashPath\\certs\\key.pem`",", "`"ClientKeyPath`": `"$sDoubleSlashPath\\machines\\$sMachineName\\key.pem`",") | Set-Content $sDirDocker/$sMachineName/config.json
    (Get-Content $sDirDocker/$sMachineName/config.json).replace("`"ClientCertPath`": `"$sDoubleSlashPath\\certs\\cert.pem`",", "`"ClientCertPath`": `"$sDoubleSlashPath\\machines\\$sMachineName\\cert.pem`",") | Set-Content $sDirDocker/$sMachineName/config.json

    (Get-Content $sDirDocker/$sMachineName/config.json).replace("server.pem","server-cert.pem") | Set-Content $sDirDocker/$sMachineName/config.json
}



function Show-Menu{
     param (
           [string]$Title = 'Photon Datacenter in a box'
     )
     cls
     Write-Host "========================================"
     Write-Host "$Title "
     Write-Host "For deployed photon instance"
     Write-Host "========================================"
    
     Write-Host "1: Press '1' Host initialization"

     Write-Host "2: TODO Press '2' Add User Client cert"

     Write-Host "3: TODO Press '3' Remove User Client cert"
     
     Write-Host "Q: Press 'Q' to quit."
}



do{
     Show-Menu
     $input = Read-Host "Please make a selection"
     switch ($input){
           '1' {
                cls
                
                if ((Read-Host "Is ssh host enabled with direct root access? (Y/N)" ) -ne "Y"){
                    echo "Unable to go ahead! Please check prerequisites"
                    return
                }

                if (($sMachineName = Read-Host "Enter machine name [my-photon]") -eq ""){$sMachineName = "my-photon"}
                if (($sHost = Read-Host "Enter ip or fqdn [192.168.119.128]") -eq ""){$sHost = "192.168.119.128"}
                if (($sUser = Read-Host "Enter ssh root username [root]") -eq ""){$sUser = "root"}
                if (($sPassword = Read-Host "Enter ssh root password **mandatory**") -eq ""){
                    echo "Unable to go ahead!"
                    return
                }

                #TODO Add ssh key access certifciate

                createDockerMachine $sHost $sMachineName
                generateServerCerts $sHost $sHostCertDir $sUser $sPassword
                setUpRemoteDockerHost $sHost $sHostCertDir $sUser $sPassword
                getMainClientCerts $sHost $sUser $sPassword $sDirDocker $sMachineName $sHostCertDir
                changeClientDockerMachine $sDirDocker $sMachineName $sDoubleSlashPath

                echo "Done!!"


           }
           #'2' {
           #     cls
           #     'TODO: Add client user '
           #}
           #'3' {
           #     cls
           #     'TODO: Remove client user'
           #}
           'q' {
                return
           }
     }
     pause
}
until ($input -eq 'q')





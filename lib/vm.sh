#!/usr/bin/env bash
# lib/vm.sh — VM helper script generation (create, attach-gpu, set-stage, ISO build).
# Sourced by passthrough-setup.sh; requires lib/common.sh, lib/windows.sh, lib/iso.sh.

create_vm_helper_scripts() {
  local vm_name="$1"
  local gpu_pci="$2"
  local gpu_audio_pci="$3"
  local ovmf_code="$4"
  local ovmf_vars="$5"
  local virtio_iso="$6"
  local usb_mode="$7"
  local usb_controller_pci="$8"
  local usb_device_ids="$9"
  local windows_test_mode="${10}"
  local winhance_payload="${11}"
  local windows_password="${12}"
  local sunshine_payload="${13:-0}"
  local looking_glass="${14:-0}"
  local existing_disk="${15:-}"

  local create_body attach_body video_xml audio_xml unattend_xml setupcomplete_body
  local build_unattend_body build_windows_body set_stage_body controller_xml usb_attach_block
  local user_name_placeholder
  local first_logon_dse_xml="" setupcomplete_dse_body="" first_logon_reboot_xml=""
  local first_logon_debloat_xml=""
  local specialize_run_commands_xml="" unattend_extensions_xml="" winhance_extensions_xml=""
  local winhance_source_xml="" escaped_windows_password

  user_name_placeholder="${SUDO_USER:-${USER:-user}}"
  winhance_source_xml="${WINHANCE_SOURCE_XML}"
  escaped_windows_password="$(xml_escape "${windows_password}")"

  # -------------------------------------------------------------------------
  # passthrough-set-stage
  # -------------------------------------------------------------------------
  set_stage_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
STAGE="${1:-}"
[[ -n "${STAGE}" ]] || {
  echo "usage: passthrough-set-stage <host-configured|spice-install|gpu-passthrough>" >&2
  exit 2
}
[[ -f "${STATE_FILE}" ]] || {
  echo "Missing ${STATE_FILE}" >&2
  exit 1
}

tmp="$(mktemp)"
if [[ ! -w "${STATE_FILE}" ]]; then
  echo "State file is not writable; skipping stage update to ${STAGE}" >&2
  exit 0
fi
awk -v stage="${STAGE}" '
  BEGIN { done = 0 }
  /^INSTALL_STAGE=/ {
    print "INSTALL_STAGE=\"" stage "\""
    done = 1
    next
  }
  { print }
  END {
    if (!done) {
      print "INSTALL_STAGE=\"" stage "\""
    }
  }' "${STATE_FILE}" > "${tmp}"
cat "${tmp}" > "${STATE_FILE}"
rm -f "${tmp}"
echo "Set install stage to ${STAGE}"
EOF
)

  # -------------------------------------------------------------------------
  # Windows test-mode unattend fragments
  # -------------------------------------------------------------------------
  if [[ "${windows_test_mode}" == "1" ]]; then
    first_logon_dse_xml=$(cat <<'EOF'
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Enable Windows test mode</Description>
          <CommandLine>cmd /c bcdedit /set {current} testsigning on</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order>
          <Description>Relax driver signature enforcement</Description>
          <CommandLine>cmd /c bcdedit /set {current} nointegritychecks on</CommandLine>
        </SynchronousCommand>
EOF
)
    first_logon_reboot_xml=$(cat <<'EOF'
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>9</Order>
          <Description>Reboot into Windows test mode</Description>
          <CommandLine>shutdown.exe /r /t 5 /f /c "Rebooting once to enable Windows test mode"</CommandLine>
        </SynchronousCommand>
EOF
)
    setupcomplete_dse_body+=$'bcdedit /set {current} testsigning on >nul 2>&1\r\n'
    setupcomplete_dse_body+=$'bcdedit /set {current} nointegritychecks on >nul 2>&1\r\n'
  fi

  # -------------------------------------------------------------------------
  # Winhance / standard specialize block
  # -------------------------------------------------------------------------
  if [[ "${winhance_payload}" == "1" ]]; then
    winhance_source_xml="$(resolve_winhance_source_xml "${winhance_source_xml}")"
    winhance_extensions_xml="$(sed -n '/<Extensions xmlns="urn:winhance:unattend">/,/<\/Extensions>/p' "${winhance_source_xml}")"
    [[ -n "${winhance_extensions_xml}" ]] || fail "Could not extract the Winhance Extensions block from ${winhance_source_xml}."
    unattend_extensions_xml="${winhance_extensions_xml}"
    specialize_run_commands_xml=$(cat <<'EOF'
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Load full Winhance payload from unattend extensions</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Allow local account creation without online requirement</Description>
          <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Disable network adapters during OOBE</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Disable-NetAdapter -Confirm:$false"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Enable .NET Framework 3.5 from Windows installation media</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -Command "foreach($d in 'C','D','E','F','G','H','I','J','K'){$src=Join-Path ($d+':') 'sources\sxs';if(Test-Path $src\*.cab){dism /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$src;break}}"</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>Run full Winhance payload</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\Winhance\Unattend\Scripts\Winhancements.ps1"</Path>
        </RunSynchronousCommand>
EOF
)
  else
    specialize_run_commands_xml=$(cat <<'EOF'
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Allow local account creation without online requirement</Description>
          <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Disable network adapters during OOBE</Description>
          <Path>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Disable-NetAdapter -Confirm:$false"</Path>
        </RunSynchronousCommand>
EOF
)
  fi

  # -------------------------------------------------------------------------
  # Autounattend.xml
  # -------------------------------------------------------------------------
  unattend_xml=$(cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <DynamicUpdate>
        <Enable>false</Enable>
        <WillShowUI>OnError</WillShowUI>
      </DynamicUpdate>
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Bypass TPM requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Bypass Secure Boot requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Bypass RAM requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Bypass CPU requirement</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>Allow upgrades with unsupported TPM or CPU</Description>
          <Path>reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>${user_name_placeholder}</FullName>
        <Organization>passthrough</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnPSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
    </component>
    <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipRearm>1</SkipRearm>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
${specialize_run_commands_xml}
      </RunSynchronous>
    </component>
    <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipAutoActivation>true</SkipAutoActivation>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PreventDeviceEncryption>true</PreventDeviceEncryption>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Username>${user_name_placeholder}</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Password>
          <Value>${escaped_windows_password}</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>${user_name_placeholder}</Name>
            <Group>Administrators</Group>
            <DisplayName>${user_name_placeholder}</DisplayName>
            <Password>
              <Value>${escaped_windows_password}</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <FirstLogonCommands>
${first_logon_dse_xml}
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>3</Order>
          <Description>Re-enable network adapters</Description>
          <CommandLine>powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter | Enable-NetAdapter -Confirm:\$false"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>4</Order>
          <Description>Install virtio guest tools if mounted</Description>
          <CommandLine>cmd /c for %D in (D E F G H I J K L M) do @if exist %D:\virtio-win-guest-tools.exe start /wait "" %D:\virtio-win-guest-tools.exe /quiet /norestart</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>5</Order>
          <Description>Install SPICE guest tools if mounted</Description>
          <CommandLine>cmd /c for %D in (D E F G H I J K L M) do @if exist %D:\spice-guest-tools.exe start /wait "" %D:\spice-guest-tools.exe /S</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>6</Order>
          <Description>Hide Edge first-run experience</Description>
          <CommandLine>reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HideFirstRunExperience" /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>7</Order>
          <Description>Show file extensions</Description>
          <CommandLine>reg.exe add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>8</Order>
          <Description>Disable hibernation</Description>
          <CommandLine>cmd /C POWERCFG -H OFF</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>10</Order>
          <Description>Disable unsupported hardware notices</Description>
          <CommandLine>reg.exe add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v SV1 /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>11</Order>
          <Description>Disable unsupported hardware notices second flag</Description>
          <CommandLine>reg.exe add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v SV2 /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
${first_logon_debloat_xml}
${first_logon_reboot_xml}
      </FirstLogonCommands>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
${unattend_extensions_xml}
  <cpi:offlineImage cpi:source="wim://windows/install.wim#Windows 11 Pro" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
EOF
)

  # -------------------------------------------------------------------------
  # SetupComplete.cmd
  # -------------------------------------------------------------------------
  setupcomplete_body=$'@echo off\r\n'
  setupcomplete_body+=$'set "PT_SETUP_LOG=%ProgramData%\\Passthrough\\SetupComplete.log"\r\n'
  setupcomplete_body+=$'set "PT_SETUP_MARKER=%Public%\\Desktop\\Passthrough Post-Install.txt"\r\n'
  setupcomplete_body+=$'if not exist "%ProgramData%\\Passthrough" mkdir "%ProgramData%\\Passthrough" >nul 2>&1\r\n'
  setupcomplete_body+=$'echo [%date% %time%] SetupComplete.cmd started>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+="${setupcomplete_dse_body}"
  setupcomplete_body+=$'for %%D in (D E F G H I J K L M) do (\r\n'
  setupcomplete_body+=$'  if exist %%D:\\virtio-win-guest-tools.exe (\r\n'
  setupcomplete_body+=$'    echo [%date% %time%] Installing virtio guest tools from %%D:>>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+=$'    start /wait "" %%D:\\virtio-win-guest-tools.exe /quiet /norestart\r\n'
  setupcomplete_body+=$'  )\r\n'
  setupcomplete_body+=$'  if exist %%D:\\spice-guest-tools.exe (\r\n'
  setupcomplete_body+=$'    echo [%date% %time%] Installing SPICE guest tools from %%D:>>"%PT_SETUP_LOG%"\r\n'
  setupcomplete_body+=$'    start /wait "" %%D:\\spice-guest-tools.exe /S\r\n'
  setupcomplete_body+=$'  )\r\n'
  setupcomplete_body+=$')\r\n'
  setupcomplete_body+=$'(\r\n'
  setupcomplete_body+=$'  echo Passthrough post-install tasks finished.\r\n'
  setupcomplete_body+=$'  echo.\r\n'
  setupcomplete_body+=$'  echo Time: %date% %time%\r\n'
  setupcomplete_body+=$'  echo Log: %PT_SETUP_LOG%\r\n'
  setupcomplete_body+=$'  echo.\r\n'
  setupcomplete_body+=$'  echo If virtio or SPICE tools were mounted, they were started from SetupComplete.cmd.\r\n'
  setupcomplete_body+=$') >"%PT_SETUP_MARKER%"\r\n'
  setupcomplete_body+=$'echo [%date% %time%] SetupComplete.cmd finished>>"%PT_SETUP_LOG%"\r\n'
  # Sunshine + VB-Cable silent install (optional, for headless Moonlight streaming)
  if [[ "${sunshine_payload}" == "1" ]]; then
    setupcomplete_body+=$'echo [%date% %time%] Installing Sunshine for Moonlight streaming...>>"%%PT_SETUP_LOG%%"\r\n'
    setupcomplete_body+=$'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$url = (Invoke-RestMethod https://api.github.com/repos/LizardByte/Sunshine/releases/latest).assets | Where-Object { $_.name -like \\\"sunshine-windows-installer.exe\\\" } | Select-Object -ExpandProperty browser_download_url; Invoke-WebRequest -Uri $url -OutFile $env:TEMP\\\\sunshine.exe -UseBasicParsing" 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'if exist \"%%TEMP%%\\sunshine.exe\" (\r\n'
    setupcomplete_body+=$'  start /wait \"\" \"%%TEMP%%\\sunshine.exe\" /S /D=\"%%ProgramFiles%%\\Sunshine\" 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'  netsh advfirewall firewall add rule name=\"Sunshine TCP\" protocol=TCP dir=in localport=47984,47989,47990,48010 action=allow >nul 2>&1\r\n'
    setupcomplete_body+=$'  netsh advfirewall firewall add rule name=\"Sunshine UDP\" protocol=UDP dir=in localport=47998,47999,48000,48002,48010 action=allow >nul 2>&1\r\n'
    setupcomplete_body+=$'  echo [%date% %time%] Sunshine installed and firewall rules added.>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$')\r\n'
    # VB-CABLE virtual audio driver (needed for headless audio capture by Sunshine)
    # Technique borrowed from Parsec-Cloud-Preparation-Tool's AudioInstall function
    setupcomplete_body+=$'echo [%date% %time%] Installing VB-Cable virtual audio driver...>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"Invoke-WebRequest -Uri https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip -OutFile $env:TEMP\\\\VBCable.zip -UseBasicParsing; Expand-Archive -Path $env:TEMP\\\\VBCable.zip -DestinationPath $env:TEMP\\\\VBCable -Force; $cat = Get-Item $env:TEMP\\\\VBCable\\\\*.cat | Select-Object -First 1; if ($cat) { $cert = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate; [IO.File]::WriteAllBytes(\\\"$env:TEMP\\\\VBCable\\\\vb.cer\\\", $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)); Import-Certificate -FilePath $env:TEMP\\\\VBCable\\\\vb.cer -CertStoreLocation Cert:\\\\LocalMachine\\\\TrustedPublisher | Out-Null }\" 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'if exist \"%%TEMP%%\\VBCable\\VBCABLE_Setup_x64.exe\" (\r\n'
    setupcomplete_body+=$'  start /wait \"\" \"%%TEMP%%\\VBCable\\VBCABLE_Setup_x64.exe\" -i -h 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'  echo [%date% %time%] VB-Cable installed.>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$')\r\n'
  fi

  if [[ "${looking_glass}" == "1" ]]; then
    setupcomplete_body+=$'echo [%date% %time%] Installing Looking Glass Host...>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$url = (Invoke-RestMethod https://api.github.com/repos/gnif/LookingGlass/releases/latest).assets | Where-Object { $_.name -like \\\"looking-glass-host-setup.exe\\\" } | Select-Object -ExpandProperty browser_download_url; Invoke-WebRequest -Uri $url -OutFile $env:TEMP\\\\lg-setup.exe -UseBasicParsing" 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'if exist \"%%TEMP%%\\lg-setup.exe\" (\r\n'
    setupcomplete_body+=$'  start /wait \"\" \"%%TEMP%%\\lg-setup.exe\" /S 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'  echo [%date% %time%] Looking Glass Host installed.>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$')\r\n'

    setupcomplete_body+=$'echo [%date% %time%] Installing IddSampleDriver (Virtual Display)...>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"Invoke-WebRequest -Uri https://github.com/ge9/IddSampleDriver/releases/download/v0.0.1/IddSampleDriver.zip -OutFile $env:TEMP\\\\Idd.zip -UseBasicParsing; Expand-Archive -Path $env:TEMP\\\\Idd.zip -DestinationPath $env:TEMP\\\\Idd -Force\" 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'if exist \"%%TEMP%%\\Idd\\install.bat\" (\r\n'
    setupcomplete_body+=$'  pushd \"%%TEMP%%\\Idd\"\r\n'
    setupcomplete_body+=$'  call install.bat 2>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$'  popd\r\n'
    setupcomplete_body+=$'  echo [%date% %time%] IddSampleDriver installed.>>\"%%PT_SETUP_LOG%%\"\r\n'
    setupcomplete_body+=$')\r\n'
  fi

  setupcomplete_body+=$'exit /b 0\r\n'

  create_body=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "\${STATE_FILE}"

WINDOWS_ISO="\${1:-\${WINDOWS_ISO:-}}"
DISK_PATH="\${DISK_PATH:-/var/lib/libvirt/images/\${VM_NAME}.qcow2}"
DISK_SIZE_GB="\${DISK_SIZE_GB:-120}"
MEMORY_MB="\${MEMORY_MB:-16384}"
VCPUS="\${VCPUS:-8}"
VIRTIO_MEDIA="\${2:-\${VIRTIO_ISO}}"
INSTALL_PROFILE="\${INSTALL_PROFILE:-standard}"
PATCHED_WINDOWS_ISO="/var/lib/libvirt/images/\${VM_NAME}-windows-install-\${INSTALL_PROFILE}.iso"

command -v virt-install >/dev/null 2>&1 || { echo "virt-install is required" >&2; exit 1; }
[[ -f "${ovmf_code}" ]] || { echo "Missing OVMF_CODE at ${ovmf_code}" >&2; exit 1; }
[[ -f "${ovmf_vars}" ]] || { echo "Missing OVMF_VARS at ${ovmf_vars}" >&2; exit 1; }

if [[ ! -f "\${PATCHED_WINDOWS_ISO}" ]]; then
  echo "Missing patched Windows ISO: \${PATCHED_WINDOWS_ISO}" >&2
  echo "Re-run: sudo \$(dirname "\$0")/../passthrough-setup.sh" >&2
  [[ -n "\${WINDOWS_ISO}" ]] && echo "Configured base Windows ISO: \${WINDOWS_ISO}" >&2
  exit 1
fi

# Always (re)create the disk with qemu-img so:
#  a) virt-install sees an existing file and never needs the size= argument
#  b) any partial prior install (EFI System Partition) is wiped, keeping
#     the HDD blank so OVMF auto-boots from the DVD without confusion.
echo "Creating blank VM disk (\${DISK_SIZE_GB}G)..."
qemu-img create -f qcow2 "\${DISK_PATH}" "\${DISK_SIZE_GB}G"

cmd=(
  virt-install
  --connect qemu:///system
  --name "\${VM_NAME}"
  --memory "\${MEMORY_MB}"
  --vcpus "\${VCPUS},sockets=1,dies=1,cores=\${VCPUS},threads=1"
  --cpu "host-passthrough"
  --machine q35
  --features "acpi=on,apic=on"
  --boot "loader=${ovmf_code},loader.readonly=yes,loader.type=pflash,nvram.template=${ovmf_vars}"
  --clock "offset=localtime"
  --network network=default,model=e1000e
  --graphics spice
  --video qxl
  --sound ich9
  --watchdog "itco,action=reset"
  --channel spicevmc
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb
  --osinfo detect=on,require=off
  --noautoconsole
  --disk "path=\${DISK_PATH},format=qcow2,bus=sata"
)

# Patched ISO has Autounattend.xml + SetupComplete.cmd embedded inside.
# OVMF auto-boots from this DVD because the HDD is blank (no EFI partition).
cmd+=(--disk "path=\${PATCHED_WINDOWS_ISO},device=cdrom")

if [[ "\${LOOKING_GLASS:-0}" == "1" ]]; then
  cmd+=(--shm "name=looking-glass,size=32")
fi

if [[ -n "\${VIRTIO_MEDIA}" && -f "\${VIRTIO_MEDIA}" ]]; then
  cmd+=(--disk "path=\${VIRTIO_MEDIA},device=cdrom")
else
  echo "virtio ISO not found; continuing without one" >&2
fi

"\${cmd[@]}"
/usr/local/bin/passthrough-set-stage spice-install
echo "VM created. OVMF will auto-boot the patched Windows ISO (blank HDD first)."
echo "If it does not, open \${VM_NAME} in virt-manager or virt-viewer."
echo "When Windows setup finishes and the VM shuts down, run ./windows again."
EOF
)


  # -------------------------------------------------------------------------
  # passthrough-build-autounattend
  # -------------------------------------------------------------------------
  build_unattend_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "${STATE_FILE}"

SRC_DIR="/etc/passthrough/autounattend"
OUT_ISO="/var/lib/libvirt/images/${VM_NAME}-autounattend.iso"

[[ -f "${SRC_DIR}/Autounattend.xml" ]] || {
  echo "Missing ${SRC_DIR}/Autounattend.xml" >&2
  exit 1
}

if command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -V AUTOUNATTEND -o "${OUT_ISO}" "${SRC_DIR}"
else
  echo "Need xorriso, genisoimage, or mkisofs to build unattended ISO" >&2
  exit 1
fi

echo "Built ${OUT_ISO}"
EOF
)

  # -------------------------------------------------------------------------
  # passthrough-build-windows-iso
  # -------------------------------------------------------------------------
  build_windows_body=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "${STATE_FILE}"

SRC_DIR="/etc/passthrough/autounattend"
BASE_ISO="${WINDOWS_ISO}"
PROFILE="${INSTALL_PROFILE:-standard}"
OUT_ISO="/var/lib/libvirt/images/${VM_NAME}-windows-install-${PROFILE}.iso"
SETUPCOMPLETE="${SRC_DIR}/\$OEM\$/\$\$/Setup/Scripts/SetupComplete.cmd"
WORKDIR="$(mktemp -d)"
ROOT_DIR="${WORKDIR}/root"

cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

[[ -f "${BASE_ISO}" ]] || { echo "Missing Windows ISO: ${BASE_ISO}" >&2; exit 1; }
[[ -f "${SRC_DIR}/Autounattend.xml" ]] || { echo "Missing ${SRC_DIR}/Autounattend.xml" >&2; exit 1; }
[[ -f "${SETUPCOMPLETE}" ]] || { echo "Missing ${SETUPCOMPLETE}" >&2; exit 1; }
command -v xorriso >/dev/null 2>&1 || { echo "Need xorriso to build patched Windows ISO" >&2; exit 1; }

# Extract the Windows ISO so we can inject our files and repack.
# Uses 7z (preferred) or bsdtar.  The resulting ISO is repacked with the
# original BIOS (etfsboot.com) and EFI (efisys.bin) boot images so OVMF
# can auto-boot from it without needing manual UEFI menu selection.
mkdir -p "${ROOT_DIR}"
if command -v 7z >/dev/null 2>&1; then
  echo "Extracting ISO with 7z..."
  7z x -y "-o${ROOT_DIR}" "${BASE_ISO}" > /dev/null
elif command -v bsdtar >/dev/null 2>&1; then
  echo "Extracting ISO with bsdtar..."
  bsdtar -C "${ROOT_DIR}" -xf "${BASE_ISO}"
else
  echo "Need 7z (p7zip) or bsdtar to extract the Windows ISO" >&2
  exit 1
fi

# Inject Autounattend.xml at root and SetupComplete.cmd in sources/$OEM$
cp "${SRC_DIR}/Autounattend.xml" "${ROOT_DIR}/Autounattend.xml"
mkdir -p "${ROOT_DIR}/sources/\$OEM\$/\$\$/Setup/Scripts"
cp "${SETUPCOMPLETE}" "${ROOT_DIR}/sources/\$OEM\$/\$\$/Setup/Scripts/SetupComplete.cmd"

[[ -f "${ROOT_DIR}/boot/etfsboot.com" ]] || {
  echo "Missing BIOS boot image: boot/etfsboot.com" >&2; exit 1
}
if [[ -f "${ROOT_DIR}/efi/microsoft/boot/efisys.bin" ]]; then
  EFI_BOOT_IMAGE="efi/microsoft/boot/efisys.bin"
elif [[ -f "${ROOT_DIR}/efi/microsoft/boot/efisys_noprompt.bin" ]]; then
  EFI_BOOT_IMAGE="efi/microsoft/boot/efisys_noprompt.bin"
else
  echo "Missing EFI boot image in extracted Windows ISO" >&2; exit 1
fi

VOLID="$(xorriso -indev "${BASE_ISO}" -pvd_info 2>/dev/null \
  | awk -F': *' '/^Volume Id/ {print $2; exit}')"
VOLID="${VOLID:-WINAUTO}"

rm -f "${OUT_ISO}"
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -J -joliet-long \
  -relaxed-filenames \
  -V "${VOLID}" \
  -o "${OUT_ISO}" \
  -b "boot/etfsboot.com" -no-emul-boot -boot-load-size 8 \
  -eltorito-alt-boot \
  -e "${EFI_BOOT_IMAGE}" -no-emul-boot \
  "${ROOT_DIR}"

echo "Built ${OUT_ISO}"
EOF
)

  # -------------------------------------------------------------------------
  # passthrough-attach-gpu (GPU/USB XML attachment + VM redefinition)
  # -------------------------------------------------------------------------
  local rom_path="/etc/passthrough/roms/vbios_${gpu_pci//[:.]/_}.rom"
  local rom_xml=""
  if [[ -f "${rom_path}" ]]; then
    log "Found custom VBIOS ROM at ${rom_path}. Injecting into VM config."
    rom_xml="<rom file='${rom_path}'/>"
  fi

  video_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${gpu_pci:0:4}' bus='0x${gpu_pci:5:2}' slot='0x${gpu_pci:8:2}' function='0x${gpu_pci:11:1}'/>
  </source>
  ${rom_xml}
</hostdev>
EOF
)

  audio_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${gpu_audio_pci:0:4}' bus='0x${gpu_audio_pci:5:2}' slot='0x${gpu_audio_pci:8:2}' function='0x${gpu_audio_pci:11:1}'/>
  </source>
</hostdev>
EOF
)

  controller_xml=""
  usb_attach_block=""
  if [[ "${usb_mode}" == "controller" && -n "${usb_controller_pci}" ]]; then
    controller_xml=$(cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${usb_controller_pci:0:4}' bus='0x${usb_controller_pci:5:2}' slot='0x${usb_controller_pci:8:2}' function='0x${usb_controller_pci:11:1}'/>
  </source>
</hostdev>
EOF
)
    usb_attach_block+=$'virsh -c qemu:///system attach-device "${VM_NAME}" /etc/passthrough/${VM_NAME}-usb-controller.xml --config\n'
  fi

  if [[ "${usb_mode}" == "evdev" ]]; then
    usb_attach_block+=$'python3 - "${xml_after}" <<\'PYXML\'\n'
    usb_attach_block+=$'import os, sys\n'
    usb_attach_block+=$'import xml.etree.ElementTree as ET\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'xml_path = sys.argv[1]\n'
    usb_attach_block+=$'tree = ET.parse(xml_path)\n'
    usb_attach_block+=$'root = tree.getroot()\n'
    usb_attach_block+=$'devices = root.find("devices")\n'
    usb_attach_block+=$'if devices is None:\n'
    usb_attach_block+=$'    raise SystemExit("domain XML missing <devices>")\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'# Collect devices already present in XML to avoid duplicates (idempotent)\n'
    usb_attach_block+=$'existing_evdev = set()\n'
    usb_attach_block+=$'for el in devices.findall("input"):\n'
    usb_attach_block+=$'    if el.get("type") == "evdev":\n'
    usb_attach_block+=$'        src = el.find("source")\n'
    usb_attach_block+=$'        if src is not None and src.get("dev"):\n'
    usb_attach_block+=$'            existing_evdev.add(os.path.realpath(src.get("dev")))\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'seen = set()\n'
    usb_attach_block+=$'for base in ("/dev/input/by-id", "/dev/input/by-path"):\n'
    usb_attach_block+=$'    if not os.path.isdir(base):\n'
    usb_attach_block+=$'        continue\n'
    usb_attach_block+=$'    for name in sorted(os.listdir(base)):\n'
    usb_attach_block+=$'        if not (name.endswith("-event-kbd") or name.endswith("-event-mouse")):\n'
    usb_attach_block+=$'            continue\n'
    usb_attach_block+=$'        dev = os.path.join(base, name)\n'
    usb_attach_block+=$'        real = os.path.realpath(dev)\n'
    usb_attach_block+=$'        if real in seen:\n'
    usb_attach_block+=$'            continue\n'
    usb_attach_block+=$'        seen.add(real)\n'
    usb_attach_block+=$'        # Skip if this device is already in the XML (idempotent re-runs)\n'
    usb_attach_block+=$'        if real in existing_evdev:\n'
    usb_attach_block+=$'            continue\n'
    usb_attach_block+=$'        input_el = ET.SubElement(devices, "input", {"type": "evdev"})\n'
    usb_attach_block+=$'        attrs = {"dev": dev, "grabToggle": "shift-shift"}\n'
    usb_attach_block+=$'        if name.endswith("-event-kbd"):\n'
    usb_attach_block+=$'            attrs["grab"] = "all"\n'
    usb_attach_block+=$'            attrs["repeat"] = "on"\n'
    usb_attach_block+=$'        ET.SubElement(input_el, "source", attrs)\n'
    usb_attach_block+=$'\n'
    usb_attach_block+=$'tree.write(xml_path, encoding="unicode")\n'
    usb_attach_block+=$'PYXML\n'
  fi

  attach_body=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/passthrough/passthrough.conf"
source "\${STATE_FILE}"
URI="qemu:///system"
PATCHED_WINDOWS_ISO="/var/lib/libvirt/images/\${VM_NAME}-windows-install-\${INSTALL_PROFILE:-standard}.iso"

iommu_group_devices() {
  local pci="\$1" group_path
  group_path="\$(readlink -f "/sys/bus/pci/devices/\${pci}/iommu_group" 2>/dev/null || true)"
  [[ -n "\${group_path}" && -d "\${group_path}/devices" ]] || return 1
  find -L "\${group_path}/devices" -maxdepth 1 -mindepth 1 -printf '%f\n' | sort
}

pci_group_isolated() {
  local pci="\$1" count
  count="\$(iommu_group_devices "\${pci}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "\${count}" == "1" ]]
}

state="\$(virsh -c "\${URI}" domstate "\${VM_NAME}" 2>/dev/null || true)"
if [[ "\${state}" == "running" ]]; then
  echo "Shut down \${VM_NAME} before finalizing GPU passthrough." >&2
  exit 1
fi

if [[ "\${USB_MODE:-none}" == "controller" && -n "\${USB_CONTROLLER_PCI:-}" ]]; then
  if ! pci_group_isolated "\${USB_CONTROLLER_PCI}"; then
    echo "Refusing to passthrough USB controller \${USB_CONTROLLER_PCI}: its IOMMU group is not isolated." >&2
    echo "Use USB device passthrough instead, or choose a controller in a standalone group." >&2
    echo "Group contents:" >&2
    iommu_group_devices "\${USB_CONTROLLER_PCI}" | while read -r dev; do
      lspci -nns "\${dev}" >&2 || true
    done
    exit 1
  fi
fi

xml_before="\$(mktemp)"
xml_after="\$(mktemp)"
trap 'rm -f "\${xml_before}" "\${xml_after}"' EXIT

virsh -c "\${URI}" dumpxml "\${VM_NAME}" > "\${xml_before}"
cp "\${xml_before}" "/etc/passthrough/\${VM_NAME}-before-gpu-passthrough.xml"
cp "\${xml_before}" "\${xml_after}"

python3 - "\${xml_after}" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
tree = ET.parse(xml_path)
root = tree.getroot()

vcpus = root.findtext("vcpu") or "4"

devices = root.find("devices")
if devices is not None:
    for child in list(devices):
        if child.tag == "disk" and child.get("device") == "cdrom":
            devices.remove(child)
        elif child.tag == "hostdev":
            devices.remove(child)
        elif child.tag == "graphics" and child.get("type") == "spice":
            devices.remove(child)
        elif child.tag == "video":
            devices.remove(child)
        elif child.tag == "channel" and child.get("type") == "spicevmc":
            devices.remove(child)
        elif child.tag == "redirdev":
            devices.remove(child)
        elif child.tag == "audio" and child.get("type") == "spice":
            devices.remove(child)
        elif child.tag == "sound":
            devices.remove(child)
        elif child.tag == "input" and child.get("type") == "tablet":
            devices.remove(child)
        elif child.tag == "shm":
            devices.remove(child)

features = root.find("features")
if features is not None:
    root.remove(features)
features = ET.Element("features")
ET.SubElement(features, "acpi")
ET.SubElement(features, "apic")
hyperv = ET.SubElement(features, "hyperv", {"mode": "custom"})
for name, state in (
    ("relaxed", "on"), ("vapic", "on"), ("spinlocks", "on"),
    ("vpindex", "on"), ("runtime", "on"), ("synic", "on"),
    ("stimer", "on"), ("frequencies", "on"),
    ("tlbflush", "off"), ("ipi", "off"), ("avic", "on"),
):
    ET.SubElement(hyperv, name, {"state": state})
# CONCEALMENT: Spoof hypervisor vendor_id to prevent CPUID 0x40000000 KVM signature
# Use a random 12-char alphanumeric string (bare-metal CPUs don't have hypervisor vendor)
# Ref: single-gpu-passthrough.wiki FAQ "I want to hide my KVM from anti-cheats"
import os as _os, hashlib as _hl
_seed = _hl.md5((_os.uname().nodename + xml_path).encode()).hexdigest()[:12]
ET.SubElement(hyperv, "vendor_id", {"state": "on", "value": _seed})
# CONCEALMENT: Hide KVM hypervisor from CPUID-based discovery
kvm_el = ET.SubElement(features, "kvm")
ET.SubElement(kvm_el, "hidden", {"state": "on"})
# CONCEALMENT: Disable PMU (Battleye/EAC probe this)
ET.SubElement(features, "pmu", {"state": "off"})
# CONCEALMENT: Disable VMware I/O port backdoor (ACE/AC checks 0x5658)
ET.SubElement(features, "vmport", {"state": "off"})
# CONCEALMENT: MSR reads to unknown registers inject #GP instead of returning 0
ET.SubElement(features, "msrs", {"unknown": "fault"})
# CONCEALMENT: Enable S3/S4 ACPI sleep states (bare-metal systems have these)
pm_el = root.find("pm")
if pm_el is None:
    pm_el = ET.SubElement(root, "pm")
ET.SubElement(pm_el, "suspend-to-mem", {"enabled": "yes"})
ET.SubElement(pm_el, "suspend-to-disk", {"enabled": "yes"})
root.insert(2, features)

cpu = root.find("cpu")
if cpu is not None:
    root.remove(cpu)
cpu = ET.Element("cpu", {"mode": "host-passthrough", "check": "none", "migratable": "on"})
ET.SubElement(cpu, "topology", {
    "sockets": "1", "dies": "1", "clusters": "1",
    "cores": vcpus.strip(), "threads": "1",
})
ET.SubElement(cpu, "cache", {"mode": "passthrough"})
# CONCEALMENT: Clear Hypervisor Present bit from CPUID.1:ECX[31]
ET.SubElement(cpu, "feature", {"policy": "disable", "name": "hypervisor"})
# CONCEALMENT: Clear speculative store bypass mitigation flags (KVM-specific)
ET.SubElement(cpu, "feature", {"policy": "disable", "name": "ssbd"})
ET.SubElement(cpu, "feature", {"policy": "disable", "name": "amd-ssbd"})
ET.SubElement(cpu, "feature", {"policy": "disable", "name": "virt-ssbd"})
# COMPAT: Enable topoext on AMD so hyperthreading topology is exposed correctly
# Ref: single-gpu-passthrough.wiki "9) Additional editing of xml file"
import os as _os2
if _os2.environ.get("CPU_VENDOR", "").lower() == "amd":
    ET.SubElement(cpu, "feature", {"policy": "require", "name": "topoext"})
insert_after = root.find("features")
insert_idx = list(root).index(insert_after) + 1 if insert_after is not None else 3
root.insert(insert_idx, cpu)

clock = root.find("clock")
if clock is not None:
    root.remove(clock)
clock = ET.Element("clock", {"offset": "localtime"})
ET.SubElement(clock, "timer", {"name": "tsc", "present": "yes", "mode": "native"})
ET.SubElement(clock, "timer", {"name": "hpet", "present": "yes"})
ET.SubElement(clock, "timer", {"name": "hypervclock", "present": "yes"})
# CONCEALMENT: Hide KVM paravirtual clock source
ET.SubElement(clock, "timer", {"name": "kvmclock", "present": "no"})
insert_after = root.find("cpu")
insert_idx = list(root).index(insert_after) + 1 if insert_after is not None else 4
root.insert(insert_idx, clock)

# CONCEALMENT: Inject host SMBIOS data (serial numbers, board info) into the os block.
# EAC reads SMBIOS serials via WMI; real host values make the VM indistinguishable.
# Ref: single-gpu-passthrough.wiki FAQ: "adding <smbios mode='host'/> to the <os> section"
os_el = root.find("os")
if os_el is not None:
    existing_smbios = os_el.find("smbios")
    if existing_smbios is None:
        ET.SubElement(os_el, "smbios", {"mode": "host"})


# PERFORMANCE: Disable virtio memballoon — kills GPU passthrough perf
if devices is not None:
    for child in list(devices):
        if child.tag == "memballoon":
            devices.remove(child)
    memballoon = ET.SubElement(devices, "memballoon", {"model": "none"})
    # Add USB mouse+keyboard inputs only if not already present (idempotent)
    existing_usb_inputs = {(c.get("type"), c.get("bus")) for c in devices if c.tag == "input"}
    if ("mouse", "usb") not in existing_usb_inputs:
        ET.SubElement(devices, "input", {"type": "mouse", "bus": "usb"})
    if ("keyboard", "usb") not in existing_usb_inputs:
        ET.SubElement(devices, "input", {"type": "keyboard", "bus": "usb"})

    if "${looking_glass}" == "1":
        shm = ET.SubElement(devices, "shm", {"name": "looking-glass"})
        ET.SubElement(shm, "size", {"unit": "MiB"}).text = "32"

tree.write(xml_path, encoding="unicode")
PY

# Pass CPU_VENDOR into the Python script via environment so topoext logic works
export CPU_VENDOR="${CPU_VENDOR:-}"

virsh -c "\\\${URI}" define "\\\${xml_after}" >/dev/null
virsh -c "\\\${URI}" attach-device "\\\${VM_NAME}" /etc/passthrough/\\\${VM_NAME}-gpu-video.xml --config
virsh -c "\\\${URI}" attach-device "\\\${VM_NAME}" /etc/passthrough/\\\${VM_NAME}-gpu-audio.xml --config
virsh -c "\\\${URI}" dumpxml "\\\${VM_NAME}" > "\\\${xml_after}"
\${usb_attach_block}
virsh -c "\\\${URI}" define "\\\${xml_after}" >/dev/null


if [[ "\${EUID}" -eq 0 ]]; then
  /usr/local/bin/passthrough-set-stage gpu-passthrough || true
elif command -v sudo >/dev/null 2>&1; then
  sudo /usr/local/bin/passthrough-set-stage gpu-passthrough || true
else
  echo "State file is not writable; skipping stage update to gpu-passthrough" >&2
fi
echo "Attached GPU${usb_mode:+ and USB} devices to \${VM_NAME} config."
echo "VM rewritten into passthrough mode (no Spice/QXL, install media removed, Hyper-V/CPU/clock tuning applied)."
echo "Next step: run ./windows from the repo directory to start the finalized passthrough VM."
EOF
)

  # -------------------------------------------------------------------------
  # Write files
  # -------------------------------------------------------------------------
  write_file "/etc/passthrough/autounattend/Autounattend.xml" "${unattend_xml}"
  write_file '/etc/passthrough/autounattend/$OEM$/$$/Setup/Scripts/SetupComplete.cmd' "${setupcomplete_body}"
  write_file "/etc/passthrough/${vm_name}-gpu-video.xml" "${video_xml}"
  write_file "/etc/passthrough/${vm_name}-gpu-audio.xml" "${audio_xml}"
  if [[ -n "${controller_xml}" ]]; then
    write_file "/etc/passthrough/${vm_name}-usb-controller.xml" "${controller_xml}"
  fi
  write_file "/usr/local/bin/passthrough-build-autounattend" "${build_unattend_body}"
  write_file "/usr/local/bin/passthrough-build-windows-iso" "${build_windows_body}"
  write_file "/usr/local/bin/passthrough-set-stage" "${set_stage_body}"
  write_file "/usr/local/bin/passthrough-create-vm" "${create_body}"
  write_file "/usr/local/bin/passthrough-attach-gpu" "${attach_body}"
  run chmod +x /usr/local/bin/passthrough-build-autounattend
  run chmod +x /usr/local/bin/passthrough-build-windows-iso
  run chmod +x /usr/local/bin/passthrough-set-stage
  run chmod +x /usr/local/bin/passthrough-create-vm
  run chmod +x /usr/local/bin/passthrough-attach-gpu
  if [[ "${SKIP_ISO:-0}" == "1" ]]; then
    ui_note "Skipping ISO generation (--skip-iso)."
  else
    run /usr/local/bin/passthrough-build-autounattend
    if [[ -f "${existing_disk}" ]]; then
      # Existing VM disk — skip ISO rebuild only if the patched ISO already exists.
      # On re-runs after a config change (winhance, sunshine, etc.) the patched ISO
      # should be rebuilt even though the disk is reused.
      local patched_iso
      patched_iso="$(bash -c 'source "${STATE_FILE}"; echo "/var/lib/libvirt/images/${VM_NAME}-windows-install-${INSTALL_PROFILE:-standard}.iso"' STATE_FILE="/etc/passthrough/passthrough.conf" 2>/dev/null || true)"
      if [[ -n "${patched_iso}" && -f "${patched_iso}" ]]; then
        ui_note "Skipping Windows ISO generation: existing patched ISO and VM disk found."
      else
        run /usr/local/bin/passthrough-build-windows-iso
      fi
    else
      run /usr/local/bin/passthrough-build-windows-iso
    fi
  fi
}

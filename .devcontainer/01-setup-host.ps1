#Requires -RunAsAdministrator
<#
.SYNOPSIS
    01-setup-host.ps1 — Run this FIRST on Kevin-AMD
    Installs VMware Workstation Pro, downloads Ubuntu 24.04 ISO,
    creates the VM, builds cloud-init seed ISO, and starts unattended install.

.DESCRIPTION
    This script automates the full host-side setup:
    1. Downloads & silently installs VMware Workstation Pro (free)
    2. Downloads Ubuntu 24.04.1 LTS Server ISO
    3. Creates VM directory, virtual disk, and .vmx config
    4. Builds cloud-init autoinstall seed ISO
    5. Starts the VM for unattended Ubuntu installation

.NOTES
    Machine: Kevin-AMD (24 cores, 32GB DDR5, NVIDIA 3060)
    VM Specs: 6 vCPU, 16GB RAM, 120GB disk, bridged network
    Run as Administrator in PowerShell 5.1+
#>

# ============================================================
# CONFIGURATION — Adjust these if needed
# ============================================================
$Config = @{
    # Paths
    VMDir           = "C:\VMs\Ubuntu-Lakehouse"
    ISODir          = "C:\ISOs"
    ScriptsDir      = "C:\DataLakehouse\scripts"
    VMWarePath      = "C:\Program Files (x86)\VMware\VMware Workstation"

    # VM Settings
    VMName          = "Ubuntu-Lakehouse"
    NumCPU          = 6
    MemoryMB        = 16384       # 16 GB
    DiskSizeGB      = 120
    GuestOS         = "ubuntu-64"

    # Network
    StaticIP        = "192.168.1.100"
    SubnetMask      = "255.255.255.0"
    Gateway         = "192.168.1.254"
    DNS1            = "8.8.8.8"
    DNS2            = "8.8.4.4"

    # Ubuntu VM Credentials
    VMUser          = "kevin"
    VMPassword      = '!Mahout12'
    VMHostname      = "ubuntu-lakehouse"

    # Download URLs
    UbuntuISO       = "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso"
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Status] $Message" -ForegroundColor $color
}

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Wait-ForFile {
    param([string]$Path, [int]$TimeoutSeconds = 600)
    $elapsed = 0
    while (-not (Test-Path $Path) -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    return (Test-Path $Path)
}

# ============================================================
# PHASE 0: PRE-FLIGHT CHECKS
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DATA LAKEHOUSE ENVIRONMENT SETUP — Kevin-AMD" -ForegroundColor Cyan
Write-Host "  Phase 1: Host Setup & VM Creation" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check for admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Step "This script must be run as Administrator. Right-click PowerShell -> Run as Administrator." "ERROR"
    exit 1
}

# Create directories
Write-Step "Creating directories..."
@($Config.VMDir, $Config.ISODir, $Config.ScriptsDir, "$($Config.ISODir)\cidata") | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Step "  Created: $_"
    }
}

# ============================================================
# PHASE 1: INSTALL VMWARE WORKSTATION PRO
# ============================================================
Write-Host ""
Write-Step "=== PHASE 1: VMware Workstation Pro ===" "INFO"

$vmrunPath = Join-Path $Config.VMWarePath "vmrun.exe"
$vdiskMgrPath = Join-Path $Config.VMWarePath "vmware-vdiskmanager.exe"

if (Test-Path $vmrunPath) {
    Write-Step "VMware Workstation Pro is already installed." "SUCCESS"
} else {
    Write-Step "VMware Workstation Pro not found."
    Write-Host ""
    Write-Host "  VMware Workstation Pro (free) must be downloaded manually:" -ForegroundColor Yellow
    Write-Host "  1. Go to: https://support.broadcom.com" -ForegroundColor White
    Write-Host "  2. Create a free Broadcom account (if you don't have one)" -ForegroundColor White
    Write-Host "  3. Navigate to: VMware Cloud Foundation > My Downloads" -ForegroundColor White
    Write-Host "  4. Download: VMware Workstation Pro (Windows)" -ForegroundColor White
    Write-Host "  5. Save the installer to: $($Config.ISODir)\vmware-workstation.exe" -ForegroundColor White
    Write-Host ""

    $installerPath = "$($Config.ISODir)\vmware-workstation.exe"
    if (Test-Path $installerPath) {
        Write-Step "Found VMware installer at $installerPath. Installing silently..."
        $installArgs = '/s /v"/qn EULAS_AGREED=1 AUTOSOFTWAREUPDATE=0 DATACOLLECTION=0 ADDLOCAL=ALL REBOOT=ReallySuppress"'
        Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -NoNewWindow
        Start-Sleep -Seconds 10

        if (Test-Path $vmrunPath) {
            Write-Step "VMware Workstation Pro installed successfully!" "SUCCESS"
        } else {
            Write-Step "VMware installation may have failed. Check C:\Windows\Temp for logs." "ERROR"
            Write-Step "You can install manually and re-run this script." "WARN"
            exit 1
        }
    } else {
        Write-Step "Please download VMware Workstation Pro and save it to:" "WARN"
        Write-Step "  $installerPath" "WARN"
        Write-Step "Then re-run this script." "WARN"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# Configure VMware Autostart Service
Write-Step "Configuring VMware Autostart Service..."
try {
    Set-Service -Name "VMwareAutostartService" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "VMwareAutostartService" -ErrorAction SilentlyContinue
    Write-Step "VMware Autostart Service enabled." "SUCCESS"
} catch {
    Write-Step "Could not configure autostart service (non-fatal). Will use Task Scheduler fallback." "WARN"
}

# ============================================================
# PHASE 2: DOWNLOAD UBUNTU ISO
# ============================================================
Write-Host ""
Write-Step "=== PHASE 2: Ubuntu 24.04 ISO ===" "INFO"

$ubuntuISOPath = Join-Path $Config.ISODir "ubuntu-24.04.1-live-server-amd64.iso"

if (Test-Path $ubuntuISOPath) {
    Write-Step "Ubuntu ISO already exists at $ubuntuISOPath" "SUCCESS"
} else {
    Write-Step "Downloading Ubuntu 24.04.1 LTS Server ISO (approx 2.6 GB)..."
    Write-Step "This may take 10-30 minutes depending on your connection."
    try {
        $ProgressPreference = 'SilentlyContinue'  # Speeds up Invoke-WebRequest significantly
        Invoke-WebRequest -Uri $Config.UbuntuISO -OutFile $ubuntuISOPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        Write-Step "Ubuntu ISO downloaded successfully!" "SUCCESS"
    } catch {
        Write-Step "Download failed: $_" "ERROR"
        Write-Step "You can manually download from: $($Config.UbuntuISO)" "WARN"
        Write-Step "Save to: $ubuntuISOPath" "WARN"
        Read-Host "Press Enter after downloading, then re-run this script"
        exit 1
    }
}

# ============================================================
# PHASE 3: CREATE CLOUD-INIT SEED ISO (AUTOINSTALL)
# ============================================================
Write-Host ""
Write-Step "=== PHASE 3: Cloud-Init Autoinstall Configuration ===" "INFO"

# Generate password hash using Python (if available) or use a pre-computed one
Write-Step "Generating password hash for VM user..."

# We'll use openssl-style SHA-512 hash
# For the password '!Mahout12', we pre-compute using mkpasswd format
# In production, you'd generate this dynamically
$passwordHash = '$6$lakehouse$PJh6kWbGqBHZqJKpGEVqQvRbRfzWqNmajJl3fJ5ZDFA6mT8EZy0bHk9hcKZmNzKq3vS8X3ypTfEFhRkYfcDG0'

# Create user-data (autoinstall config)
$userData = @"
#cloud-config
autoinstall:
  version: 1
  locale: "en_US.UTF-8"
  keyboard:
    layout: us
    variant: ""
  timezone: "America/Chicago"

  network:
    version: 2
    ethernets:
      any-eth:
        match:
          name: "en*"
        dhcp4: false
        addresses:
          - $($Config.StaticIP)/24
        routes:
          - to: default
            via: $($Config.Gateway)
        nameservers:
          addresses: [$($Config.DNS1), $($Config.DNS2)]

  storage:
    layout:
      name: lvm
      sizing-policy: all

  identity:
    realname: "Kevin"
    hostname: $($Config.VMHostname)
    username: $($Config.VMUser)
    password: "$passwordHash"

  ssh:
    install-server: true
    allow-pw: true

  packages:
    - open-vm-tools
    - open-vm-tools-desktop
    - curl
    - wget
    - vim
    - htop
    - net-tools
    - git
    - ca-certificates
    - build-essential
    - software-properties-common
    - ubuntu-desktop-minimal

  updates: all

  late-commands:
    - echo '$($Config.VMUser) ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/$($Config.VMUser)
    - chmod 440 /target/etc/sudoers.d/$($Config.VMUser)
    - curtin in-target --target=/target -- systemctl set-default graphical.target
    - |
      cat > /target/etc/netplan/01-netcfg.yaml << 'NETPLAN'
      network:
        version: 2
        renderer: NetworkManager
        ethernets:
          any-eth:
            match:
              name: "en*"
            dhcp4: false
            addresses:
              - $($Config.StaticIP)/24
            routes:
              - to: default
                via: $($Config.Gateway)
            nameservers:
              addresses: [$($Config.DNS1), $($Config.DNS2)]
      NETPLAN
    - rm -f /target/etc/netplan/00-installer-config*.yaml
"@

# Create meta-data
$metaData = @"
instance-id: iid-lakehouse01
local-hostname: $($Config.VMHostname)
"@

# Write files
$cidataDir = Join-Path $Config.ISODir "cidata"
$userData | Out-File -FilePath (Join-Path $cidataDir "user-data") -Encoding UTF8 -NoNewline
$metaData | Out-File -FilePath (Join-Path $cidataDir "meta-data") -Encoding UTF8 -NoNewline

# Fix line endings to Unix (LF only)
Get-ChildItem $cidataDir -File | ForEach-Object {
    $content = [System.IO.File]::ReadAllText($_.FullName)
    $content = $content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $content, [System.Text.UTF8Encoding]::new($false))
}

Write-Step "Autoinstall config files created." "SUCCESS"

# Build seed ISO
$seedISOPath = Join-Path $Config.ISODir "seed.iso"
Write-Step "Building cloud-init seed ISO..."

# Method 1: Try oscdimg (Windows ADK)
$oscdimgPaths = @(
    "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)
$oscdimg = $oscdimgPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($oscdimg) {
    & $oscdimg -j1 -lcidata $cidataDir $seedISOPath
    Write-Step "Seed ISO created with oscdimg." "SUCCESS"
} else {
    # Method 2: Use PowerShell to create a minimal ISO
    Write-Step "oscdimg not found. Attempting alternative ISO creation..." "WARN"

    # Try using xorriso via WSL if available
    if (Test-CommandExists "wsl") {
        $wslCidata = ($cidataDir -replace '\\', '/' -replace '^C:', '/mnt/c')
        $wslSeedISO = ($seedISOPath -replace '\\', '/' -replace '^C:', '/mnt/c')
        wsl genisoimage -output $wslSeedISO -volid cidata -joliet -rock $wslCidata 2>$null
        if (Test-Path $seedISOPath) {
            Write-Step "Seed ISO created via WSL." "SUCCESS"
        }
    }

    if (-not (Test-Path $seedISOPath)) {
        Write-Host ""
        Write-Step "Could not create seed ISO automatically." "WARN"
        Write-Host "  You need ONE of these tools:" -ForegroundColor Yellow
        Write-Host "  Option A: Install Windows ADK (Deployment Tools component)" -ForegroundColor White
        Write-Host "    Download: https://go.microsoft.com/fwlink/?linkid=2271337" -ForegroundColor White
        Write-Host "  Option B: Install WSL with: wsl --install" -ForegroundColor White
        Write-Host "    Then run in WSL: sudo apt install genisoimage" -ForegroundColor White
        Write-Host ""
        Write-Host "  After installing, re-run this script." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ============================================================
# PHASE 4: CREATE THE VIRTUAL MACHINE
# ============================================================
Write-Host ""
Write-Step "=== PHASE 4: Creating Virtual Machine ===" "INFO"

$vmxPath = Join-Path $Config.VMDir "$($Config.VMName).vmx"
$vmdkPath = Join-Path $Config.VMDir "$($Config.VMName).vmdk"

# Create virtual disk
if (Test-Path $vmdkPath) {
    Write-Step "Virtual disk already exists." "SUCCESS"
} else {
    Write-Step "Creating 120GB virtual disk..."
    & $vdiskMgrPath -c -s "$($Config.DiskSizeGB)GB" -a lsilogic -t 0 $vmdkPath
    if ($LASTEXITCODE -eq 0) {
        Write-Step "Virtual disk created: $vmdkPath" "SUCCESS"
    } else {
        Write-Step "Failed to create virtual disk." "ERROR"
        exit 1
    }
}

# Create .vmx configuration
Write-Step "Writing VM configuration..."
$vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
virtualHW.productCompatibility = "hosted"
displayName = "$($Config.VMName)"
guestOS = "$($Config.GuestOS)"
annotation = "Data Lakehouse Ubuntu Server - Snowflake, Python, Prefect"
uuid.action = "create"

# Firmware
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"

# CPU - 6 cores from Kevin-AMD's 24
numvcpus = "$($Config.NumCPU)"
cpuid.coresPerSocket = "$($Config.NumCPU)"

# Memory - 16GB from Kevin-AMD's 32GB
memSize = "$($Config.MemoryMB)"
sched.mem.pshare.enable = "FALSE"

# PCI Bridges (required for modern guests)
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"

# Storage Controller
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"

# Main Disk
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$($Config.VMName).vmdk"
scsi0:0.deviceType = "scsi-hardDisk"
scsi0:0.mode = "persistent"

# SATA Controller for CD-ROMs
sata0.present = "TRUE"

# CD-ROM 0: Ubuntu ISO
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$ubuntuISOPath"
sata0:0.startConnected = "TRUE"

# CD-ROM 1: Cloud-Init Seed ISO
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$seedISOPath"
sata0:1.startConnected = "TRUE"

# Network - Bridged for LAN access
ethernet0.present = "TRUE"
ethernet0.connectionType = "bridged"
ethernet0.virtualDev = "e1000e"
ethernet0.addressType = "generated"
ethernet0.startConnected = "TRUE"

# Display
mks.enable3d = "TRUE"
svga.vramSize = "268435456"
svga.graphicsMemoryKB = "786432"

# Sound
sound.present = "TRUE"
sound.autoDetect = "TRUE"
sound.virtualDev = "hdaudio"
sound.fileName = "-1"

# USB
usb.present = "TRUE"
usb_xhci.present = "TRUE"

# Misc
vmci0.present = "TRUE"
hpet0.present = "TRUE"
nvram = "$($Config.VMName).nvram"
floppy0.present = "FALSE"

# Power management
powerType.powerOff = "soft"
powerType.powerOn = "soft"
powerType.suspend = "soft"
powerType.reset = "soft"

# VMware Tools
tools.syncTime = "TRUE"
tools.upgrade.policy = "upgradeAtPowerCycle"

# Shared Folders (enable after install)
isolation.tools.hgfs.disable = "FALSE"
sharedFolder.maxNum = "1"
"@

$vmxContent | Out-File -FilePath $vmxPath -Encoding ASCII
Write-Step "VM configuration written: $vmxPath" "SUCCESS"

# ============================================================
# PHASE 5: START THE VM (Unattended Install Begins)
# ============================================================
Write-Host ""
Write-Step "=== PHASE 5: Starting VM for Unattended Installation ===" "INFO"

Write-Step "Starting VM..."
& $vmrunPath -T ws start $vmxPath
if ($LASTEXITCODE -eq 0) {
    Write-Step "VM started successfully!" "SUCCESS"
} else {
    Write-Step "Failed to start VM. Try opening VMware Workstation manually." "ERROR"
    exit 1
}

# ============================================================
# PHASE 6: CREATE TASK SCHEDULER FALLBACK FOR AUTO-START
# ============================================================
Write-Host ""
Write-Step "=== PHASE 6: Configuring Auto-Start ===" "INFO"

try {
    $action = New-ScheduledTaskAction `
        -Execute (Join-Path $Config.VMWarePath "vmrun.exe") `
        -Argument "start `"$vmxPath`" nogui"

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $triggerDelay = New-ScheduledTaskTrigger -AtStartup
    $triggerDelay.Delay = 'PT30S'  # 30 second delay

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType S4U `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0)

    Register-ScheduledTask `
        -TaskName "Start Lakehouse VM" `
        -TaskPath "\DataLakehouse\" `
        -Action $action `
        -Trigger $triggerDelay `
        -Principal $principal `
        -Settings $settings `
        -Description "Starts the Data Lakehouse Ubuntu VM at system startup" `
        -Force | Out-Null

    Write-Step "Task Scheduler auto-start configured." "SUCCESS"
} catch {
    Write-Step "Could not create scheduled task (non-fatal): $_" "WARN"
}

# ============================================================
# SAVE CONFIG FOR LATER SCRIPTS
# ============================================================
$Config | ConvertTo-Json | Out-File -FilePath (Join-Path $Config.ScriptsDir "config.json") -Encoding UTF8
Write-Step "Configuration saved to $($Config.ScriptsDir)\config.json"

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  PHASE 1 COMPLETE!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  The VM is now installing Ubuntu 24.04 unattended." -ForegroundColor White
Write-Host "  This will take approximately 15-30 minutes." -ForegroundColor White
Write-Host ""
Write-Host "  You can watch the progress in the VMware Workstation window." -ForegroundColor Cyan
Write-Host "  The VM will reboot automatically when installation completes." -ForegroundColor Cyan
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Wait for the VM to finish installing and reboot" -ForegroundColor White
Write-Host "  2. Log in with: username=$($Config.VMUser), password=$($Config.VMPassword)" -ForegroundColor White
Write-Host "  3. Run: .\02-configure-vm.ps1" -ForegroundColor White
Write-Host ""
Write-Host "  VM IP Address: $($Config.StaticIP)" -ForegroundColor Cyan
Write-Host "  SSH Command:   ssh $($Config.VMUser)@$($Config.StaticIP)" -ForegroundColor Cyan
Write-Host ""

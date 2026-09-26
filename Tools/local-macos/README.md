# Local macOS development VM

This setup runs macOS 26 in a QEMU/KVM virtual machine managed by Docker Desktop.
The GUI is available in a browser at <http://127.0.0.1:8006>.

## First installation

From PowerShell in the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File Tools/local-macos/macos-vm.ps1 start
```

The first start downloads the container and the macOS recovery image. In the
browser installer, open **Disk Utility**, erase the largest Apple disk as APFS,
close Disk Utility, and install macOS on that disk. Several automatic reboots
are expected. Do not delete the Docker volume named
`classroomtranslator_macos_disk`; it contains the installed VM.

After macOS setup, install Xcode 26 from Apple, open Terminal, and run:

```bash
cd /shared/ClassroomTranslator
swift build
swift run ClassroomTranslator
```

The Windows checkout is mounted at `/shared/ClassroomTranslator`, so edits made
on either side are immediately visible to the other.

## Daily use

```powershell
# Start the VM and open its GUI
powershell -ExecutionPolicy Bypass -File Tools/local-macos/macos-vm.ps1 start

# Show state or follow boot logs
powershell -ExecutionPolicy Bypass -File Tools/local-macos/macos-vm.ps1 status
powershell -ExecutionPolicy Bypass -File Tools/local-macos/macos-vm.ps1 logs

# Shut down macOS from its Apple menu, then stop the container
powershell -ExecutionPolicy Bypass -File Tools/local-macos/macos-vm.ps1 stop
```

The VM receives 8 CPU cores, 12 GB RAM, and a dynamically allocated 160 GB
virtual disk. Docker Desktop currently has 16 GB available, so leave Docker's
memory limit at 16 GB or raise it before starting the VM.

The container pins `oscdn.apple.com` to an Akamai edge because this machine's
split-DNS route selects a domestic CDN node that closes range downloads early.
This override affects only the macOS container.

## Limitations

- macOS 26 is currently much slower in this QEMU setup than macOS 15.
- There is no accelerated Apple-compatible GPU. SwiftUI works, but animations
  and Xcode can be sluggish.
- Microphone, speech recognition, signing, and Apple Account services may need
  extra configuration or may not work reliably in the VM.
- Apple's macOS license generally permits virtualization only on Apple-branded
  hardware. This configuration is for local technical evaluation.

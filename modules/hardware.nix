# Board-specific hardware configuration for Mono Gateway DK (LS1046A)
# Boot, kernel, DTB, eMMC tuning, serial console, fancontrol, watchdog
{ config, lib, pkgs, ... }:

{
  # --- Boot ---
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.grub.enable = false;
  boot.kernelPackages = pkgs.linuxPackagesFor pkgs.mono-gateway-kernel;
  boot.kernelParams = [
    "console=ttyS0,115200"
    "earlycon=uart8250,mmio,0x21c0500"
  ];

  # Embedded board: all boot-critical drivers are built-in, no default x86 modules
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [ ];

  # Grow root filesystem to fill eMMC partition on first boot
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.e2fsprogs}/sbin/resize2fs
  '';
  boot.initrd.postMountCommands = ''
    resize2fs /dev/mmcblk0p1 || true
  '';

  # Explicit DTB for extlinux.conf FDT entry
  hardware.deviceTree.name = "freescale/mono-gateway-dk-sdk.dtb";

  # --- Filesystems ---
  fileSystems."/" = {
    device = "/dev/mmcblk0p1";
    fsType = "ext4";
    options = [
      "noatime"    # no access-time writes — biggest single win for eMMC
      "commit=60"  # flush journal every 60s instead of 5s — coalesces writes
    ];
  };

  # --- Serial console ---
  # Deliberately unconfigured. The console is instantiated by systemd's own
  # getty generator (kernel cmdline console=ttyS0,115200 ->
  # /run/systemd/generator/getty.target.wants/serial-getty@ttyS0.service), and
  # NixOS's template ExecStart -- agetty --login-program .../login %I
  # --keep-baud -- is what runs, so the port asks for a login.
  #
  # This used to declare, on serial-getty@ttyS0.service:
  #
  #     serviceConfig.ExecStart = [ "" "@...agetty --autologin root ..." ];
  #
  # which never took effect: NixOS applies the serial-getty@ template and its
  # overrides.conf drop-in after the instance fragment, and that drop-in
  # starts with a bare `ExecStart=` that clears the list. Verified with
  # `systemctl cat serial-getty@ttyS0.service` -- the effective ExecStart is
  # NixOS's default, no --autologin. Kept here as a comment because the
  # instance-level form is the trap: anything that has to win over the stock
  # getty goes on the template, not the instance.

  # Auto-detect terminal size on serial console
  programs.bash.loginShellInit = ''
    [ "$TERM" != "dumb" ] && eval "$(resize)" 2>/dev/null
  '';

  # --- eMMC wear reduction ---
  boot.kernel.sysctl = {
    "vm.dirty_writeback_centisecs" = 6000;
    "vm.dirty_expire_centisecs" = 6000;
  };

  services.fstrim.enable = true;

  # Journal: volatile only (RAM) to avoid eMMC writes
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=50M
  '';

  # --- Fancontrol (EMC2305) ---
  hardware.fancontrol.enable = true;
  hardware.fancontrol.config = builtins.readFile ../pkgs/fancontrol/fancontrol.conf;

  # --- Out-of-tree hardware kernel modules ---
  boot.extraModulePackages = [
    pkgs.mono-gateway-sfp-led
    pkgs.mono-gateway-lp5812-driver
  ];

  # --- Watchdog ---
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  systemd.settings.Manager.RebootWatchdogSec = "60s";
}

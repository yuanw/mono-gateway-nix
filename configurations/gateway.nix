{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/hardware.nix
    ../modules/networking.nix
    ../modules/ask-offload.nix
  ];

  # --- ASK fast path ---
  mono-gateway.ask.enable = true;

  # --- Users ---
  # Root gets no password from here. This was
  #
  #     users.users.root.initialHashedPassword = "";  # empty password for serial console
  #
  # which left /etc/shadow as `root::1:...`, and pam_unix takes a bare username
  # against an empty hash: `root` + Enter at the serial console (the board boots
  # console=ttyS0,115200 and systemd's getty generator instantiates
  # serial-getty@ttyS0) walked straight into a root shell. Measured on a live
  # board. Physical access is not authentication -- these sit in a hallway, on
  # the outside of a WAN port. If you want a console login, set
  # users.users.root.hashedPassword in your own host config together with
  # users.mutableUsers = false; with mutableUsers = true a password option is
  # only honoured when the user is created, so it silently does nothing to an
  # existing root.
  users.users.root.openssh.authorizedKeys.keys = [
    # Managed manually on the device (~/.ssh/authorized_keys)
  ];

  # --- Userspace packages ---
  environment.systemPackages = with pkgs; [
    mono-gateway-status-led
    lm_sensors
    htop
    vim
    xterm  # provides 'resize' for serial console auto-sizing
    tcpdump
    ethtool
    conntrack-tools
    iperf3
    mtr
  ];

  # --- Nix ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # --- Minimization ---
  documentation.enable = false;

  # --- First-boot Nix store registration ---
  boot.postBootCommands = ''
    if [ -f /nix-path-registration ]; then
      ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
      touch /etc/NIXOS
      rm -f /nix-path-registration
    fi
  '';

  system.stateVersion = "25.11";
}

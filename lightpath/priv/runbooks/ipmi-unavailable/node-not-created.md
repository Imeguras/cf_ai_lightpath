Draft by Claude (2026-11-08), not reviewed yet. Read-only checks first:

  ls -l /dev/ipmi* /dev/ipmi/ 2>&1
  ls /sys/class/ipmi/
  journalctl -k -b | grep -i ipmi        (needs the systemd-journal group)

If the kernel log shows ipmi_si found the interface (KCS/SSIF) but there is
no ipmi0 under /sys/class/ipmi, reload the device interface so it attaches:

  doas modprobe -r ipmi_devintf
  doas modprobe ipmi_devintf

If ipmi_si never found an interface, the BMC's system interface may be off
in UEFI (IMM settings) or the IMM needs a reset from its web UI.

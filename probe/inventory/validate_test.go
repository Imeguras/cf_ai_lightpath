package inventory_test

import (
	"regexp"
	"slices"
	"strings"
	"testing"

	"homelab-copilot/probe/inventory"
)

func cmd(id string, argv ...string) inventory.Command {
	return inventory.Command{ID: id, Argv: argv, Why: "test"}
}

func TestValidateAcceptsWellFormedList(t *testing.T) {
	cmds := []inventory.Command{
		cmd("uname", "uname", "-a"),
		cmd("zfs-dkms-meta", "find", "/usr/src", "-path", "/usr/src/zfs-*/META", "-exec", "cat", "{}", "+"),
		cmd("a_b-9", "printf", "%s; | & $HOME `x` 'q' \"d\"", "with space"),
	}
	if err := inventory.Validate(cmds); err != nil {
		t.Fatalf("Validate(valid list) = %v, want nil", err)
	}
}

func TestValidateRejectsEmptyList(t *testing.T) {
	if err := inventory.Validate(nil); err == nil {
		t.Error("Validate(nil) = nil, want error")
	}
	if err := inventory.Validate([]inventory.Command{}); err == nil {
		t.Error("Validate(empty) = nil, want error")
	}
}

func TestValidateRejectsBadIDs(t *testing.T) {
	for _, id := range []string{"", "Uname", "-lead", "_lead", "has space", "../escape", "a/b", "a.json", "é"} {
		err := inventory.Validate([]inventory.Command{cmd(id, "uname")})
		if err == nil {
			t.Errorf("Validate(ID %q) = nil, want error", id)
		}
	}
}

func TestValidateRejectsDuplicateIDs(t *testing.T) {
	err := inventory.Validate([]inventory.Command{cmd("x", "uname"), cmd("y", "uptime"), cmd("x", "true")})
	if err == nil {
		t.Error("Validate(duplicate IDs) = nil, want error")
	}
}

func TestValidateRejectsEmptyArgv(t *testing.T) {
	if err := inventory.Validate([]inventory.Command{cmd("x")}); err == nil {
		t.Error("Validate(empty argv) = nil, want error")
	}
}

func TestValidateRejectsBadProgramNames(t *testing.T) {
	bad := []string{"/usr/bin/uname", "bin/uname", "un ame", "un\tame", ""}
	for _, c := range ";|&$`<>()*?[]{}'\"\\~!" {
		bad = append(bad, "un"+string(c)+"ame")
	}
	for _, p := range bad {
		if err := inventory.Validate([]inventory.Command{cmd("x", p)}); err == nil {
			t.Errorf("Validate(Argv[0] %q) = nil, want error", p)
		}
	}
}

func TestValidateRejectsEscalationAndShells(t *testing.T) {
	for _, p := range []string{"doas", "sudo", "fudo", "su", "pkexec", "run0", "sh", "bash", "zsh", "dash", "fish"} {
		if err := inventory.Validate([]inventory.Command{cmd("x", p, "zpool", "status")}); err == nil {
			t.Errorf("Validate(Argv[0] %q) = nil, want error", p)
		}
	}
}

func TestValidateRejectsNULAndNewlineInAnyArg(t *testing.T) {
	for _, argv := range [][]string{
		{"uname", "a\x00b"},
		{"uname", "a\nb"},
		{"uname", "-a", "ok", "tail\n"},
	} {
		if err := inventory.Validate([]inventory.Command{cmd("x", argv...)}); err == nil {
			t.Errorf("Validate(argv %q) = nil, want error", argv)
		}
	}
}

func TestValidateErrorDoesNotDependOnPosition(t *testing.T) {
	good := cmd("good", "uname")
	bad := cmd("bad", "sudo", "ls")
	for _, list := range [][]inventory.Command{{bad, good}, {good, bad}} {
		if err := inventory.Validate(list); err == nil {
			t.Errorf("Validate(%v) = nil, want error", list)
		}
	}
}

func TestSelectEmptyReturnsAll(t *testing.T) {
	all := []inventory.Command{cmd("a", "true"), cmd("b", "true")}
	got, err := inventory.Select(all, nil)
	if err != nil || len(got) != 2 || got[0].ID != "a" || got[1].ID != "b" {
		t.Fatalf("Select(all, nil) = %v, %v; want all commands", got, err)
	}
}

func TestSelectKeepsListOrderAndIgnoresRepeats(t *testing.T) {
	all := []inventory.Command{cmd("a", "true"), cmd("b", "true"), cmd("c", "true")}
	got, err := inventory.Select(all, []string{"c", "a", "c"})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, c := range got {
		ids = append(ids, c.ID)
	}
	if !slices.Equal(ids, []string{"a", "c"}) {
		t.Errorf("Select order = %v, want [a c]", ids)
	}
}

func TestSelectUnknownIDIsError(t *testing.T) {
	if _, err := inventory.Select([]inventory.Command{cmd("a", "true")}, []string{"a", "nope"}); err == nil {
		t.Error("Select(unknown ID) error = nil, want error")
	}
}

func TestDefaultCommandsAreValid(t *testing.T) {
	if err := inventory.Validate(inventory.DefaultCommands()); err != nil {
		t.Fatalf("Validate(DefaultCommands()) = %v", err)
	}
}

func TestDefaultCommandsIncludeZFSCaseIDs(t *testing.T) {
	have := map[string]bool{}
	for _, c := range inventory.DefaultCommands() {
		have[c.ID] = true
	}
	for _, id := range []string{"uname", "pacman-q", "pacman-kernel-zfs", "zfs-dkms-meta", "dkms-status", "modinfo-zfs", "zpool-status", "virsh-system-pools"} {
		if !have[id] {
			t.Errorf("DefaultCommands() lacks ID %q", id)
		}
	}
}

func TestDefaultCommandsHaveReasons(t *testing.T) {
	for _, c := range inventory.DefaultCommands() {
		if strings.TrimSpace(c.Why) == "" {
			t.Errorf("command %q has no Why", c.ID)
		}
	}
}

// The doc promises coverage areas; check one representative program per area.
func TestDefaultCommandsCoverAreas(t *testing.T) {
	progs := map[string]bool{}
	for _, c := range inventory.DefaultCommands() {
		progs[c.Argv[0]] = true
	}
	for area, want := range map[string][]string{
		"kernel":     {"uname"},
		"packages":   {"pacman"},
		"zfs":        {"zpool", "zfs"},
		"systemd":    {"systemctl", "journalctl"},
		"disks":      {"lsblk"},
		"network":    {"ip", "ethtool"},
		"sensors":    {"sensors"},
		"ipmi":       {"ipmitool"},
		"libvirt":    {"virsh"},
		"kubernetes": {"kubectl"},
		"docker":     {"docker"},
		"pcp":        {"pminfo"},
	} {
		if !slices.ContainsFunc(want, func(p string) bool { return progs[p] }) {
			t.Errorf("area %s: none of %v in DefaultCommands()", area, want)
		}
	}
}

func TestDefaultCommandsLibvirtIsReadOnly(t *testing.T) {
	for _, c := range inventory.DefaultCommands() {
		if c.Argv[0] == "virsh" && !slices.Contains(c.Argv, "-r") && !slices.Contains(c.Argv, "--readonly") {
			t.Errorf("virsh command %q does not use a read-only connection", c.ID)
		}
	}
}

func TestDefaultCommandsReturnsFreshSlice(t *testing.T) {
	a := inventory.DefaultCommands()
	a[0].ID = "mutated"
	a[0].Argv[0] = "mutated"
	b := inventory.DefaultCommands()
	if b[0].ID == "mutated" || b[0].Argv[0] == "mutated" {
		t.Error("modifying DefaultCommands() result changed a later call")
	}
}

var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

func TestDefaultCommandIDsMatchDocumentedPattern(t *testing.T) {
	for _, c := range inventory.DefaultCommands() {
		if !idPattern.MatchString(c.ID) {
			t.Errorf("ID %q does not match %s", c.ID, idPattern)
		}
	}
}

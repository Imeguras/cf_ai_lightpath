// Command inventory runs the phase 1 read-only command list against the
// homelab (over ssh, or locally) and saves the raw output as private fixtures.
//
//	inventory -list
//	inventory -target micron@<host> [-only id,id] [-out dir] [-timeout 30s]
//	inventory -local [-only id,id] [-out dir]
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"homelab-copilot/probe/inventory"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "inventory:", err)
		os.Exit(1)
	}
}

func run() error {
	target := flag.String("target", "", "ssh destination, e.g. user@host")
	local := flag.Bool("local", false, "run the commands on this machine instead of over ssh")
	only := flag.String("only", "", "comma-separated command IDs to run (default: all)")
	out := flag.String("out", "", "new directory for the fixtures (default: fixtures/raw/<timestamp>)")
	timeout := flag.Duration("timeout", 30*time.Second, "time limit per command")
	list := flag.Bool("list", false, "print the command list and exit without running anything")
	flag.Parse()

	cmds := inventory.DefaultCommands()
	if err := inventory.Validate(cmds); err != nil {
		return err
	}
	var ids []string
	if *only != "" {
		ids = strings.Split(*only, ",")
	}
	cmds, err := inventory.Select(cmds, ids)
	if err != nil {
		return err
	}

	if *list {
		for _, c := range cmds {
			fmt.Printf("%-24s %s\n%-24s   # %s\n", c.ID, inventory.RemoteCommandLine(c.Argv), "", c.Why)
		}
		return nil
	}

	var runner inventory.Runner
	label := *target
	switch {
	case *local && *target != "":
		return fmt.Errorf("use either -local or -target, not both")
	case *local:
		runner = inventory.LocalRunner{}
		if label, err = os.Hostname(); err != nil {
			label = "local"
		}
	case *target != "":
		runner = inventory.SSHRunner{Target: *target}
	default:
		return fmt.Errorf("-target or -local is required (or -list)")
	}

	now := time.Now()
	dir := *out
	if dir == "" {
		dir = filepath.Join("fixtures", "raw", now.UTC().Format("20060102T150405Z"))
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	results := inventory.RunAll(ctx, runner, cmds, *timeout)

	if err := inventory.WriteFixtures(dir, label, now.UTC(), results); err != nil {
		return err
	}
	failed := 0
	for _, r := range results {
		status := fmt.Sprintf("exit %d", r.ExitCode)
		if r.Error != "" {
			status = "error: " + r.Error
			failed++
		}
		fmt.Printf("%-24s %s\n", r.ID, status)
	}
	fmt.Printf("\n%d commands, %d could not run; fixtures in %s\n", len(results), failed, dir)
	return nil
}

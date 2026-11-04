// Command scrub turns private inventory fixtures into a public fixture set.
//
//	scrub -config private/scrub.json -out fixtures/public/<name> fixtures/raw/<run> [fixtures/raw/<later-run> ...]
//
// Later runs replace fixtures with the same ID from earlier ones.
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"

	"lightpath/probe/scrub"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "scrub:", err)
		os.Exit(1)
	}
}

func run() error {
	configPath := flag.String("config", "private/scrub.json", "private scrub config (literals and dropped IDs)")
	out := flag.String("out", "", "new directory for the public fixtures")
	flag.Parse()
	if *out == "" || flag.NArg() == 0 {
		return fmt.Errorf("usage: scrub -config FILE -out DIR RUN_DIR [RUN_DIR...]")
	}

	cfg, err := scrub.LoadConfig(*configPath)
	if err != nil {
		return err
	}
	s, err := scrub.New(cfg)
	if err != nil {
		return err
	}
	if err := s.Fixtures(flag.Args(), *out); err != nil {
		return err
	}

	counts := s.Counts()
	kinds := make([]string, 0, len(counts))
	for k := range counts {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	fmt.Printf("public fixtures written to %s; leak check passed\ndistinct values replaced:\n", *out)
	for _, k := range kinds {
		fmt.Printf("  %-8s %d\n", k, counts[k])
	}
	return nil
}

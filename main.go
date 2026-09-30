// Command carson is a git tool for coding agents that work in the same repositories at once. It starts, shows, lands, removes, abandons
// and adopts tasks, each in its own worktree, so that local main only moves forward, and only by a finished task landing. It keeps no
// state of its own beyond one owner record per worktree, runs only when called, and reports what it observed, not what it attempted.
package main

import (
	"fmt"
	"os"
)

func main() {
	dir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stdout, "%s the current folder cannot be read (%v); run carson from a folder that exists.\n", Badge, err)
		os.Exit(failed)
	}
	os.Exit(Main(os.Args[1:], ThisMachine(dir, os.Stdout)))
}

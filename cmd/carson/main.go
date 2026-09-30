// Command carson is the git tool for the master's agents: it starts, shows, merges and removes tasks, each in its own worktree.
package main

import (
	"fmt"
	"os"

	"github.com/wanghailei/carson/internal/carson"
)

func main() {
	dir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stdout, "carson: the current folder cannot be read: %v\n", err)
		os.Exit(1)
	}
	os.Exit(carson.Main(os.Args[1:], carson.ThisMachine(dir, os.Stdout)))
}

//go:build !windows

package main

func processWorkingSet(pid int) uint64 { return 0 }

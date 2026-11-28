//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"unsafe"
)

var getProcessMemoryInfo = windows.NewLazySystemDLL("psapi.dll").NewProc("GetProcessMemoryInfo")

// PROCESS_MEMORY_COUNTERS uses pointer-sized SIZE_T fields after two DWORDs.
type processMemoryCounters struct {
	Size, PageFaults                                                 uint32
	PeakWorkingSet, WorkingSet                                       uintptr
	PeakPaged, Paged, PeakNonPaged, NonPaged, Pagefile, PeakPagefile uintptr
}

func processWorkingSet(pid int) uint64 {
	if pid <= 0 {
		return 0
	}
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_INFORMATION|windows.PROCESS_VM_READ, false, uint32(pid))
	if err != nil {
		return 0
	}
	defer windows.CloseHandle(handle)
	counters := processMemoryCounters{}
	counters.Size = uint32(unsafe.Sizeof(counters))
	ok, _, _ := getProcessMemoryInfo.Call(uintptr(handle), uintptr(unsafe.Pointer(&counters)), uintptr(counters.Size))
	if ok == 0 {
		return 0
	}
	return uint64(counters.WorkingSet)
}

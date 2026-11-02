//go:build darwin

package main

import (
	"golang.org/x/sys/unix"
	"net"
	"path/filepath"
)

type PeerInfo struct {
	PID              int
	Process          string
	Executable       string
	ParentPID        int
	ParentProcess    string
	ParentExecutable string
}

func resolvePeer(conn net.Conn) PeerInfo {
	pid := peerPID(conn)
	if pid <= 0 {
		return PeerInfo{}
	}
	return lookupPeer(pid)
}

func peerPID(conn net.Conn) int {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0
	}
	var pid int
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		pid, sockErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	}); err != nil {
		return 0
	}
	if sockErr != nil {
		return 0
	}
	return pid
}

func lookupPeer(pid int) PeerInfo {
	info := PeerInfo{PID: pid}
	info.Executable = executablePath(pid)
	if info.Executable != "" {
		info.Process = filepath.Base(info.Executable)
	}
	process, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err == nil && process.Eproc.Ppid > 1 {
		info.ParentPID = int(process.Eproc.Ppid)
		info.ParentExecutable = executablePath(info.ParentPID)
		if info.ParentExecutable != "" {
			info.ParentProcess = filepath.Base(info.ParentExecutable)
		}
	}
	return info
}

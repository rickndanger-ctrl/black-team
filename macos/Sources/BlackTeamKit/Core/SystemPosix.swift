#if !os(Linux)
import Foundation

// The spellings Core/SystemLinux.swift gives Linux's two C libraries; on a Mac the system names are used as they are.
let posixSockStream = Int32(SOCK_STREAM)
#endif

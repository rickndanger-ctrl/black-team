import Foundation
import BlackTeamKit
#if canImport(Darwin)
import Darwin
#else
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif
#endif

/// Ctrl-C and the signals that end the program. While a reply runs in the session, Ctrl-C only stops that reply; anywhere else
/// (and for the other signals) the terminal is put back, the job and the model are shut down, and the program exits.
enum Interrupts {
    static let replying = Flag()
    static let stopReply = Flag()
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func install(_ backend: Backend) {
        for (number, status) in [(SIGINT, Int32(130)), (SIGTERM, 143), (SIGHUP, 129), (SIGQUIT, 131)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if number == SIGINT, replying.isSet {
                    stopReply.set()
                    backend.cancel()
                    return
                }
                // Ctrl-\ pauses a running Code job between steps, and lets a paused one go on.
                if number == SIGQUIT, let message = backend.togglePause() {
                    FileHandle.standardError.write(Data(("\n" + message + "\n").utf8))
                    return
                }
                Terminal.leaveRaw()
                backend.cancel()
                backend.cancelSetUp()
                backend.cancelOptimize()
                Task {
                    await backend.shutdown()
                    exit(status)
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}

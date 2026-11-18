import Darwin
import Foundation

/// Connects to the local, explicitly administrator-authorized key helper.
/// The helper sends only status and Consumer usage for the configured remote.
final class G9N9NLocalKeyCapture {
    enum Event {
        case ready, target, disconnected, usage(UInt16), failed
    }

    private var directory: String?
    private var listener: DispatchSourceRead?
    private var reader: DispatchSourceRead?
    private var process: Process?
    private var pending = Data()
    var onEvent: ((Event) -> Void)?

    deinit { stop() }

    func start(helper: URL) throws {
        precondition(Thread.isMainThread)
        stop()
        guard let remoteAddress = UserDefaults.standard.string(forKey: "g9n9n.localBluetoothAddress")?.uppercased(),
              remoteAddress.range(of: #"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$"#, options: .regularExpression) != nil else {
            AppLogger.shared.write("G9N9N HCI state=local_bluetooth_address_required")
            throw POSIXError(.EINVAL)
        }
        var template = Array("/private/tmp/sayall-key.XXXXXX".utf8CString)
        guard let folder = template.withUnsafeMutableBufferPointer({ bytes in
            mkdtemp(bytes.baseAddress!).map { String(cString: $0) }
        }) else { throw POSIXError(.EIO) }
        directory = folder
        let path = folder + "/events.sock"
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { stop(); throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(socketFD, 1) == 0 else {
            close(socketFD)
            stop()
            throw POSIXError(.EIO)
        }

        let listener = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        listener.setCancelHandler { close(socketFD) }
        listener.setEventHandler { [weak self] in self?.acceptPeer(on: socketFD) }
        self.listener = listener
        listener.resume()

        let process = Process()
        let command = "exec " + Self.shellQuote(helper.path) + " " + Self.shellQuote(path) + " " + Self.shellQuote(remoteAddress)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.process = nil
                self.fail()
            }
        }
        self.process = process
        do { try process.run() }
        catch { self.process = nil; stop(); throw error }
    }

    func stop() {
        // Closing the stream asks the privileged helper to restore diagnostics
        // before exiting. If authorization is still pending, cancel that prompt.
        let accepted = reader != nil
        reader?.cancel()
        reader = nil
        listener?.cancel()
        listener = nil
        if !accepted, let process, process.isRunning { process.terminate() }
        process = nil
        pending.removeAll()
        if let directory {
            unlink(directory + "/events.sock")
            rmdir(directory)
        }
        directory = nil
    }

    private func acceptPeer(on listenerFD: Int32) {
        guard let listener, listener.handle == listenerFD, reader == nil else { return }
        let client = accept(listenerFD, nil, nil)
        guard client >= 0 else { return }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == 0,
              fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { close(client); return }
        listener.cancel()
        self.listener = nil
        let reader = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
        reader.setCancelHandler { close(client) }
        reader.setEventHandler { [weak self] in self?.readEvents(from: client) }
        self.reader = reader
        reader.resume()
    }

    private func readEvents(from client: Int32) {
        guard let reader, reader.handle == UInt(client) else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { fail(); return }
        pending.append(contentsOf: bytes.prefix(count))
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            switch line {
            case "READY": onEvent?(.ready)
            case "TARGET": onEvent?(.target)
            case "RELEASE": onEvent?(.disconnected)
            case let line where line.hasPrefix("U "):
                if let usage = UInt16(line.dropFirst(2)) { onEvent?(.usage(usage)) }
            case let line where line.hasPrefix("ERROR "):
                fail()
                return
            default: break
            }
        }
        if pending.count > 4_096 { fail() }
    }

    private func fail() {
        stop()
        onEvent?(.failed)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

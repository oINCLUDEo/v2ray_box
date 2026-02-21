import Foundation

class XrayProcess {
    static let shared = XrayProcess()
    
    private var process: Process?
    private(set) var isRunning: Bool = false
    private let lock = NSLock()
    
    private init() {}
    
    func getBinaryPath() -> String? {
        let binaryName = "xray"
        
        var possiblePaths: [String] = []
        
        if let executablePath = Bundle.main.executablePath {
            let contentsPath = (executablePath as NSString).deletingLastPathComponent
            possiblePaths.append("\(contentsPath)/../Frameworks/\(binaryName)")
            possiblePaths.append("\(contentsPath)/../Resources/\(binaryName)")
            possiblePaths.append("\(contentsPath)/\(binaryName)")
        }
        if let mainBundlePath = Bundle.main.resourcePath {
            possiblePaths.append("\(mainBundlePath)/../Frameworks/\(binaryName)")
            possiblePaths.append("\(mainBundlePath)/\(binaryName)")
        }
        
        let bundle = Bundle(for: type(of: self))
        if let bundlePath = bundle.resourcePath {
            possiblePaths.append("\(bundlePath)/../Frameworks/\(binaryName)")
            possiblePaths.append("\(bundlePath)/Frameworks/\(binaryName)")
            possiblePaths.append("\(bundlePath)/\(binaryName)")
        }
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path),
               FileManager.default.isExecutableFile(atPath: path) {
                print("V2rayBox: Found xray binary at \(path)")
                return path
            }
        }
        
        print("V2rayBox: xray binary not found in: \(possiblePaths)")
        return nil
    }
    
    func getVersion() -> String {
        guard let binaryPath = getBinaryPath() else { return "" }
        
        do {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = ["version"]
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            proc.waitUntilExit()
            
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if let match = output.range(of: #"Xray (\S+)"#, options: .regularExpression) {
                let versionLine = output[match]
                let version = versionLine.replacingOccurrences(of: "Xray ", with: "")
                return version
            }
            return output.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            print("V2rayBox: Failed to get xray version: \(error)")
            return ""
        }
    }
    
    func start(configPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if isRunning {
            print("V2rayBox: xray is already running")
            return true
        }
        
        guard let binaryPath = getBinaryPath() else {
            print("V2rayBox: xray binary not found")
            return false
        }
        
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = ["run", "-c", configPath]
            proc.environment = ["XRAY_LOCATION_ASSET": (configPath as NSString).deletingLastPathComponent]
            
            let outputPipe = Pipe()
            proc.standardOutput = outputPipe
            proc.standardError = outputPipe
            
            proc.terminationHandler = { [weak self] p in
                print("V2rayBox: xray process exited with code: \(p.terminationStatus)")
                self?.lock.lock()
                self?.isRunning = false
                self?.process = nil
                self?.lock.unlock()
            }
            
            try proc.run()
            process = proc
            isRunning = true
            
            DispatchQueue.global(qos: .background).async {
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                        print("XrayCore: \(line)")
                    }
                }
            }
            
            Thread.sleep(forTimeInterval: 0.5)
            if proc.isRunning {
                print("V2rayBox: xray started successfully")
                return true
            } else {
                print("V2rayBox: xray process died immediately")
                isRunning = false
                process = nil
                return false
            }
        } catch {
            print("V2rayBox: Failed to start xray: \(error)")
            isRunning = false
            process = nil
            return false
        }
    }
    
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        guard let proc = process else { return }
        
        print("V2rayBox: Stopping xray process")
        proc.terminate()
        proc.waitUntilExit()
        
        process = nil
        isRunning = false
        print("V2rayBox: xray stopped")
    }
}

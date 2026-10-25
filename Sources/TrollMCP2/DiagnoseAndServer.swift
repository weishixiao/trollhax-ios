import Foundation

// v2.9.71：自动诊断 + 本地 HTTP 服务
// 1. 自动诊断 — 启动failed/崩溃/注入failed自动判因，给出修复建议
// 2. 本地 HTTP 服务 — localhost REST API，其他脚本/工具可调用

// MARK: - 自动诊断工具

final class DiagnoseStartupTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose.startup",
        summary: "Auto-diagnose why an app won't launch. Use for: app crashes on start, won't open, find out why. Don't use for: read crash logs (use shell.exec), inject dylib (use injection.enable). Example: user says '小红书 crashes on open' → diagnose startup failure.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "auto_fix": "Auto try to fix (default false, just diagnose)"
        ],
        verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let autoFix = (params["auto_fix"] as? Bool) ?? false

        var diagnosis: [String: Any] = ["bundle_id": bundleId]
        var causes: [String] = []
        var fixes: [String] = []

        // 1. 检查 App 是否存在
        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "App not installed: \(bundleId)", "fix": "reinstall with TrollStore"]
        }
        diagnosis["app_path"] = target.path

        // 2. 检查主二进制
        let exec = (NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? ""
        let binaryPath = target.path.appending("/\(exec)")
        diagnosis["binary_exists"] = FileManager.default.fileExists(atPath: binaryPath)
        if !FileManager.default.fileExists(atPath: binaryPath) {
            causes.append("main binary does not exist")
            fixes.append("reinstall the App")
        }

        // 3. 检查架构 (v2.9.125：arch unknown = 解析failed (可能加密），不误判"非 arm64"）
        let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [binaryPath])
        let isArm64 = fileOutput.contains("arm64")
        let isOtherArch = fileOutput.contains("x86_64") || fileOutput.contains("armv7") || fileOutput.contains("i386")
        if isArm64 {
            diagnosis["arch"] = "arm64"
        } else if isOtherArch {
            diagnosis["arch"] = "non-arm64"
        } else {
            diagnosis["arch"] = "unknown"
            diagnosis["arch_note"] = "parse failed (maybe encrypted or special Mach-O), does not mean unlaunchable/uninjectable; judge with cryptid"
        }
        if isOtherArch {
            causes.append("非 arm64 架构")
            fixes.append("确认 IPA 是 arm64 构建")
        }

        // 4. 检查签名
        // v6.9.5：直接读 LC_CODE_SIGNATURE，不 spawn ldid（rootHide 下 spawnRoot 恒返回 85，
        // 旧实现会把空输出误判成"二进制未签名"）
        if let staticEnts = AppEntitlementsTool.entitlementsViaMachO(path: binaryPath) {
            let count = staticEnts["count"] as? Int ?? 0
            diagnosis["signed"] = true
            diagnosis["entitlements_count"] = count
            diagnosis["signed_source"] = "machokit"
            if count == 0 {
                causes.append("有签名但 entitlements 为空（ad-hoc 签名或被剥离）")
                fixes.append("判断是否需要 task_for_pid-allow：ad-hoc 签名需用 ldid -S<plist> 重签")
            }
        } else {
            diagnosis["signed"] = false
            causes.append("二进制无 LC_CODE_SIGNATURE（未签名或被剥离）")
            fixes.append("用 ldid 重新签名或用 TrollStore 重装")
        }

        // 5. 检查注入状态和备份
        let backupPath = binaryPath.appending(".bak_macho")
        diagnosis["has_backup"] = FileManager.default.fileExists(atPath: backupPath)
        let frameworksDir = target.path.appending("/Frameworks")
        if let dylibs = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            diagnosis["injected_dylibs"] = dylibs.filter { $0.hasSuffix(".dylib") }
        }

        // 6. 检查最近崩溃日志
        let crashDir = NSHomeDirectory().appending("/Library/Logs/CrashReporter")
        var recentCrash: String?
        if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
            let relevant = files.filter { $0.contains(bundleId) || $0.contains(exec) }
            if let latest = relevant.sorted().last {
                recentCrash = crashDir.appending("/\(latest)")
                diagnosis["recent_crash"] = latest
                // 读取崩溃原因
                if let content = try? String(contentsOfFile: recentCrash!) {
                    let lines = content.components(separatedBy: .newlines)
                    for line in lines.prefix(30) {
                        if line.contains("Exception Type") || line.contains("Termination Reason") || line.contains("dyld") || line.contains("code signature") {
                            causes.append("崩溃: \(line.trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }

        // 7. 尝试启动并观察
        let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
        Thread.sleep(forTimeInterval: 3)
        let pid = findPid(by: bundleId)
        diagnosis["launch_pid"] = pid
        diagnosis["launched"] = pid > 0
        if pid == 0 {
            causes.append("启动后 3 秒内进程消失 (闪退)")
            fixes.append("检查崩溃日志中的 dyld 错误，通常是注入的 dylib 依赖缺失")
        }

        // 8. 自动修复
        if autoFix && !causes.isEmpty {
            // 如果有备份且注入了 dylib，尝试恢复备份
            if FileManager.default.fileExists(atPath: backupPath) {
                let _ = InjectionManager.shared.spawnRoot("/bin/cp", args: [backupPath, binaryPath])
                fixes.append("已恢复主二进制备份")
            }
        }

        diagnosis["causes"] = causes
        diagnosis["fixes"] = fixes
        diagnosis["verdict"] = causes.isEmpty ? "✅ 启动正常" : "❌ 发现 \(causes.count) 个问题"
        // v2.9.125：CLI 式一句话结论
        diagnosis["message"] = causes.isEmpty
            ? "未发现启动问题 (arch=\(diagnosis["arch"] ?? "unknown"))"
            : "发现 \(causes.count) 个问题：\(causes.prefix(3).joined(separator: "；"))"

        return diagnosis
    }
}

final class DiagnoseCrashTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose.crash",
        summary: "Analyze crash logs and symbolicate raw frame addresses into function names. Reads both system CrashReporter reports and the app's own CrashCatcher logs (Workspace/crash). Use for: app keeps crashing, find out why, locate the exact function a crash happened in, TrollHax itself闪退. Don't use for: read raw crash log (use shell.exec), diagnose startup failure (use diagnose.startup). Example: user says '小红书 keeps crashing, why' → analyze crash; user says '崩溃日志里这串地址是什么函数' → symbolize.",
        parameters: [
            "bundle_id": "Target App bundle ID (optional; omit to analyze this app's own CrashCatcher logs)",
            "count": "How many recent crashes to analyze (default 1, max 20)",
            "dsym": "Optional dSYM path (.app.dSYM dir or the DWARF file). Improves symbol accuracy for stripped binaries",
            "symbolicate": "Symbolicate CrashCatcher frames (default true)"
        ],
    verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = (params["bundle_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let count = max(1, min((params["count"] as? Int) ?? 1, 20))
        let wantSymbols = (params["symbolicate"] as? Bool) ?? true
        let dsymParam = params["dsym"] as? String

        var result: [String: Any] = [:]
        if !bundleId.isEmpty { result["bundle_id"] = bundleId }

        // ---- 1) CrashCatcher 自身的 sig_/exc_ 日志（Workspace/crash）----
        // v6.9.6：旧实现只读 CrashReporter，完全看不到 CrashCatcher 落盘的裸帧地址，
        // 于是"有日志但定位不到函数"。现在把两边都读，并对 sig_ 日志做符号化。
        let own = analyzeCrashCatcherLogs(count: count, dsymPaths: dsymParam.map { [$0] } ?? [],
                                          wantSymbols: wantSymbols)
        if !own.isEmpty { result["crash_catcher"] = own }

        // ---- 2) 系统 CrashReporter（第三方 App 的 .ips/.crash）----
        var analyses: [[String: Any]] = []
        if !bundleId.isEmpty {
            analyses = analyzeSystemReports(bundleId: bundleId, count: count)
        }

        if analyses.isEmpty && own.isEmpty {
            result["result"] = bundleId.isEmpty
                ? "no crash log found (Workspace/crash 为空，系统 CrashReporter 也未指定 bundle_id)"
                : "no crash log found"
            result["hint"] = bundleId.isEmpty
                ? "带上 bundle_id 可分析其他 App 的系统崩溃报告；或先触发一次崩溃让 CrashCatcher 落盘"
                : "确认 bundle_id 正确，或改用 diagnose.crash 不带 bundle_id 分析本 App 自身日志"
            return result
        }

        if !analyses.isEmpty {
            result["crash_count"] = analyses.count
            result["analyses"] = analyses
        }

        // 汇总：把符号化命中的函数提到顶层，AI 不必自己翻嵌套结构
        if wantSymbols, let tops = result["crash_catcher"] as? [[String: Any]], let first = tops.first {
            result["top_frames"] = first["frames"] ?? []
            result["next_step"] = "按 top_frames 里的 function 定位代码；偏移 = function 起点 + symbol_offset"
        }
        return result
    }
    // MARK: - CrashCatcher 日志符号化

    /// 读 Workspace/crash 下最新的 sig_/exc_ 日志。sig_ 会做符号化（地址 → 函数名），
    /// exc_ 是 ObjC 未捕获异常，调用栈本来就是符号化的，只摘关键行。
    private func analyzeCrashCatcherLogs(count: Int, dsymPaths: [String], wantSymbols: Bool) -> [[String: Any]] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: CrashCatcher.crashDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let sorted = files
            .filter { $0.pathExtension == "txt" }
            .sorted { l, r in
                let lv = (try? l.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rv = (try? r.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lv > rv
            }
            .prefix(count)

        var out: [[String: Any]] = []
        for url in sorted {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var item: [String: Any] = ["file": url.lastPathComponent, "size": text.utf8.count]

            // exc_*：ObjC 异常文本；sig_exc_*：同一现场的裸地址记录（走下面的符号化分支）
            if url.lastPathComponent.hasPrefix("exc_") {
                // ObjC 异常：name / reason / 前 8 行调用栈（已是符号名，不需再解析）
                let lines = text.components(separatedBy: .newlines)
                item["kind"] = "uncaught_exception"
                for line in lines {
                    if line.hasPrefix("name:") { item["exception_name"] = line.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces) }
                    if line.hasPrefix("reason:") { item["reason"] = line.replacingOccurrences(of: "reason:", with: "").trimmingCharacters(in: .whitespaces) }
                }
                item["stack_top8"] = lines.filter { $0.contains("0x") }.prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }
                out.append(item)
                continue
            }

            item["kind"] = "signal"
            guard let rec = CrashRecord.parse(text: text, path: url.path) else {
                item["parse_error"] = "日志头行无法解析"
                out.append(item)
                continue
            }
            item["signal"] = rec.signal ?? "?"
            item["frame_count"] = rec.frames.count
            if let b = rec.base { item["base"] = SymbolicatedHelpers.hex(b) }
            if let f = rec.fault { item["fault"] = SymbolicatedHelpers.hex(f) }
            if let v = rec.version { item["app_version"] = v }
            if let i = rec.ish { item["alpine_enabled"] = i }
            if let ts = rec.timestamp { item["crashed_at"] = ISO8601DateFormatter().string(from: ts) }
            if let u = rec.uuid { item["uuid"] = CrashSymbolicator.formattedUUID(u) }

            guard wantSymbols else {
                item["raw_frames"] = rec.frames.prefix(24).map { SymbolicatedHelpers.hex($0) }
                out.append(item)
                continue
            }
            let sym = CrashSymbolicator.symbolicate(record: rec, dsymPaths: dsymPaths, limit: 32)
            let json = sym.asJSON()
            item["uuid_match"] = json["uuid_match"] ?? "unknown"
            item["image"] = json["image"] ?? [:]
            item["frames"] = json["frames"] ?? []
            item["symbols_ok"] = json["ok"] ?? false
            let notes = (json["notes"] as? [String]) ?? []
            if !notes.isEmpty { item["notes"] = notes }
            out.append(item)
        }
        return out
    }

    // MARK: - 系统 CrashReporter 报告

    private func analyzeSystemReports(bundleId: String, count: Int) -> [[String: Any]] {
        let crashDir = NSHomeDirectory().appending("/Library/Logs/CrashReporter")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) else { return [] }
        let relevant = files.filter { $0.contains(bundleId) }.sorted().suffix(count)
        var analyses: [[String: Any]] = []
        for file in relevant {
            let path = crashDir.appending("/\(file)")
            guard let content = try? String(contentsOfFile: path) else { continue }
            var analysis: [String: Any] = ["file": file]
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Exception Type:") {
                    analysis["exception_type"] = trimmed.replacingOccurrences(of: "Exception Type: ", with: "")
                } else if trimmed.hasPrefix("Exception Subtype:") {
                    analysis["exception_subtype"] = trimmed.replacingOccurrences(of: "Exception Subtype: ", with: "")
                } else if trimmed.hasPrefix("Termination Reason:") {
                    analysis["termination_reason"] = trimmed.replacingOccurrences(of: "Termination Reason: ", with: "")
                } else if trimmed.hasPrefix("Triggered by Thread:") {
                    analysis["crashed_thread"] = trimmed.replacingOccurrences(of: "Triggered by Thread: ", with: "")
                } else if trimmed.contains("dyld") && (trimmed.contains("error") || trimmed.contains("missing") || trimmed.contains("symbol")) {
                    analysis["dyld_error"] = trimmed
                } else if trimmed.contains("code signature") || trimmed.contains("invalid") {
                    analysis["signature_issue"] = trimmed
                }
            }

            // 提取崩溃线程调用栈 (前 10 帧）
            var inCrashedThread = false
            var stack: [String] = []
            for line in lines {
                if line.contains("Thread \(analysis["crashed_thread"] ?? "0") Crashed:") {
                    inCrashedThread = true
                    continue
                }
                if inCrashedThread {
                    if line.hasPrefix("Thread") && !line.contains("Crashed") { break }
                    if !line.isEmpty { stack.append(line.trimmingCharacters(in: .whitespaces)) }
                    if stack.count >= 10 { break }
                }
            }
            analysis["stack_top10"] = stack

            // 根因判断
            var rootCause = "未知"
            if let term = analysis["termination_reason"] as? String {
                if term.contains("CODESIGNING") { rootCause = "签名失效" }
                else if term.contains("DYLD") { rootCause = "动态库加载failed" }
                else if term.contains("0xdead10cc") { rootCause = "后台挂起时持有文件锁" }
            }
            if analysis["dyld_error"] != nil { rootCause = "dyld 依赖缺失或符号未找到" }
            if analysis["signature_issue"] != nil { rootCause = "代码签名问题" }
            analysis["root_cause"] = rootCause

            // 修复建议
            switch rootCause {
            case "签名失效":
                analysis["fix"] = "reinstall via TrollStore, or re-sign main binary with ldid -S"
            case "动态库加载failed", "dyld 依赖缺失或符号未找到":
                analysis["fix"] = "check injected dylib dependencies (otool -L), confirm all dependencies exist on device"
            case "后台挂起时持有文件锁":
                analysis["fix"] = "close file handles and DB connections before App goes background"
            default:
                analysis["fix"] = "read full crash log and stack trace to locate the exact code"
            }

            analyses.append(analysis)
        }
        return analyses
    }
}

// MARK: - 本地 HTTP 服务

final class LocalServerManager {
    static let shared = LocalServerManager()
    private(set) var serverSocket: Int32 = -1
    private var isRunning = false
    private var acceptThread: Thread?

    var port: Int = 0

    func start(port: Int = 8765) -> Bool {
        guard !isRunning else { return true }

        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return false }

        var optval: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            serverSocket = -1
            return false
        }

        guard listen(serverSocket, 16) == 0 else {
            close(serverSocket)
            serverSocket = -1
            return false
        }

        self.port = port
        isRunning = true

        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.start()

        return true
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        acceptThread = nil
    }

    private func acceptLoop() {
        while isRunning && serverSocket >= 0 {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleClient(client)
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        var buffer = [CChar](repeating: 0, count: 8192)
        let bytesRead = recv(client, &buffer, 8192, 0)
        guard bytesRead > 0 else { return }

        let request = String(cString: buffer)
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let path = parts[1]

        var responseBody = ""
        var statusCode = 200

        // 路由
        if path == "/health" {
            // v2.9.125：动态读 Info.plist，不再硬编码
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            responseBody = "{\"status\":\"ok\",\"version\":\"\(ver)\",\"port\":\(port)}"
        } else if path == "/tools" {
            let tools = ToolRegistry.shared.allToolNames()
            if let data = try? JSONSerialization.data(withJSONObject: tools),
               let str = String(data: data, encoding: .utf8) {
                responseBody = str
            }
        } else if path.hasPrefix("/api/") {
            // 简单的 API 调用：/api/tool_name?param=value
            let toolName = String(path.dropFirst(5))
            if let tool = ToolRegistry.shared.tool(named: toolName) {
                // 解析 query 参数
                var params: [String: Any] = [:]
                if let queryStart = path.firstIndex(of: "?") {
                    let query = String(path[path.index(after: queryStart)...])
                    for pair in query.components(separatedBy: "&") {
                        let kv = pair.components(separatedBy: "=")
                        if kv.count == 2 {
                            params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                        }
                    }
                }
                do {
                    let result = try tool.invoke(params)
                    // v2.9.125：网关输出与聊天侧统一 CLI 结构 (ok/message/data）
                    var data = result
                    data.removeValue(forKey: "message")
                    let msg = (result["message"] as? String)
                        ?? FailureKind.defaultSuccessMessage(name: toolName, result: result)
                    if let d = try? JSONSerialization.data(withJSONObject: ["ok": true, "message": msg, "data": data], options: .prettyPrinted),
                       let str = String(data: d, encoding: .utf8) {
                        responseBody = str
                    }
                } catch {
                    statusCode = 500
                    // failed也分类输出
                    let text = (error as? MCPError)?.description ?? error.localizedDescription
                    let info = FailureKind.classify(text)
                    let body: [String: Any] = [
                        "ok": false, "message": text,
                        "error": ["code": info.code, "reason": info.reason, "next_step": info.nextStep]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted),
                       let str = String(data: d, encoding: .utf8) {
                        responseBody = str
                    }
                }
            } else {
                statusCode = 404
                responseBody = "{\"error\":\"tool not found: \(toolName)\"}"
            }
        } else {
            statusCode = 404
            responseBody = "{\"error\":\"not found\"}"
        }

        let response = "HTTP/1.1 \(statusCode) OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = response.withCString { ptr in
            send(client, ptr, Int(strlen(ptr)), 0)
        }
    }
}

final class ServerStartTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.start",
        summary: "Start the local HTTP server. Use for: enable external tools/scripts to call TrollHax via REST API. Don't use for: stop server (use server.stop), check server status (use server.status). Example: user says 'start local server' → start server.",
        parameters: [
            "port": "Port number (default 8765)"
        ], verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let port = (params["port"] as? Int) ?? 8765
        let ok = LocalServerManager.shared.start(port: port)
        return [
            "message": ok ? "local HTTP server started (127.0.0.1:\(LocalServerManager.shared.port))" : "start failed (port in use or insufficient permission)",
            "started": ok,
            "port": LocalServerManager.shared.port,
            "base_url": "http://127.0.0.1:\(LocalServerManager.shared.port)",
            "endpoints": [
                "/health — 健康检查",
                "/tools — 列出所有可用工具",
                "/api/{tool_name}?param=value — 调用工具"
            ]
        ]
    }
}

final class ServerStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.stop",
        summary: "Stop the local HTTP server. Use for: turn off the local web server, save battery. Don't use for: start server (use server.start), check server status (use server.status). Example: user says 'stop local server' → stop server.",
        parameters: [:],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        LocalServerManager.shared.stop()
        return ["stopped": true]
    }
}

final class ServerStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "server.status",
        summary: "Check if the local HTTP server is running. Use for: see if server is up, check what port it's on. Don't use for: start server (use server.start), stop server (use server.stop). Example: user says 'is local server running' → check server status.",
        parameters: [:],
    verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return [
            "running": LocalServerManager.shared.serverSocket >= 0,
            "port": LocalServerManager.shared.port,
            "available_tools": ToolRegistry.shared.allToolNames().count
        ]
    }
}

// MARK: - v3.1.36: server 大工具 + 子命令 (合并 3 个 server.* 工具）

final class ServerExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "server",
        summary: "Manage local HTTP server (start/stop/status). Use subcommand to specify action. Use for: start/stop localhost API server. Don't use for: network capture (use network.capture). Example: start → server start port:8080; status → server status. Subcommands: start / stop / status.",
        parameters: [
            "command": "Subcommand: start / stop / status",
            "port": "Port number (for start)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("server", detail: command)
        
        switch command {
        case "start":
            var p: [String: Any] = [:]
            if let port = params["port"] as? Int { p["port"] = port }
            return try ServerStartTool().invoke(p)
            
        case "stop":
            return try ServerStopTool().invoke([:])
            
        case "status":
            return try ServerStatusTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: start/stop/status")
        }
    }
}

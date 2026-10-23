// SpawnDiag.swift — 内置二进制为什么起不来（进程内诊断，不依赖任何子进程）
//
// 真机现象：bin/python3、bin/r2、bin/bsdtar 全部
//   posix_spawn failed: Bad executable (or shared library)
// 这条错误只说"坏可执行文件"，不区分：
//   ① 文件不存在 / 没有执行位
//   ② 不是 Mach-O（被 ELF 覆盖、下载损坏）
//   ③ 缺 LC_CODE_SIGNATURE（重签时被 strip）
//   ④ 签名没被 AMFI 接受（entitlements 与签名身份不匹配）
//   ⑤ 依赖的 framework 不在 @rpath（Bad executable 也会这么报）
// 这个诊断把这五项分别查出来，全部在进程内完成——即使所有 spawn 都失败也能跑。

import Foundation

enum SpawnDiag {

    struct MachOInfo {
        var magic: String = "-"
        var isMachO = false
        var hasCodeSignature = false
        var cryptid: UInt32 = 0
        var rpaths: [String] = []
        var dylibs: [String] = []
    }

    static func readMachO(_ path: String) -> MachOInfo {
        var info = MachOInfo()
        guard let fh = FileHandle(forReadingAtPath: path) else { return info }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 32), head.count == 32 else { return info }
        let magicLE = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        info.magic = String(format: "%08x", magicLE)
        let is64 = (magicLE == 0xfeedfacf)
        let isFat = (magicLE == 0xcafebabe) || (magicLE == 0xbebafeca)
        info.isMachO = is64 || magicLE == 0xfeedface || isFat
        guard is64 else { return info }   // 只解析 thin arm64 头部

        let ncmds: UInt32 = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds: UInt32 = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        guard ncmds > 0, ncmds < 4096, sizeofcmds < 4 << 20 else { return info }
        guard let body = try? fh.read(upToCount: Int(sizeofcmds)), body.count == Int(sizeofcmds) else { return info }

        var off = 0
        for _ in 0..<ncmds {
            guard off + 8 <= body.count else { break }
            let cmd: UInt32 = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
            let size: UInt32 = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self) }
            guard size >= 8, off + Int(size) <= body.count else { break }
            switch cmd {
            case 0x1D:   // LC_CODE_SIGNATURE
                info.hasCodeSignature = true
            case 0x21:   // LC_ENCRYPTION_INFO
                info.cryptid = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 16, as: UInt32.self) }
            case 0x2C:   // LC_ENCRYPTION_INFO_64
                info.cryptid = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 16, as: UInt32.self) }
            case 0x8000001C:  // LC_RPATH
                let s = cString(body, off + 12)
                if !s.isEmpty { info.rpaths.append(s) }
            case 0xC:    // LC_LOAD_DYLIB
                let s = cString(body, off + 24)
                if !s.isEmpty { info.dylibs.append(s) }
            default:
                break
            }
            off += Int(size)
        }
        return info
    }

    /// lc_str：从命令内的相对偏移读到 NUL
    private static func cString(_ data: Data, _ start: Int) -> String {
        guard start < data.count else { return "" }
        var bytes: [UInt8] = []
        var i = start
        while i < data.count && data[i] != 0 && bytes.count < 256 {
            bytes.append(data[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func run() -> [String: Any] {
        // 诊断要真实探测，先清掉上一次的"被拦截"记忆
        BuildRunner.resetSpawnBlock()
        let fm = FileManager.default
        let binDir = Bundle.main.bundlePath + "/bin"
        let names = ["python3", "node", "r2", "cstool", "lua", "jq", "bsdtar", "ldid"]

        var rows: [[String: Any]] = []
        for n in names {
            let p = binDir + "/" + n
            guard fm.fileExists(atPath: p) else {
                rows.append(["name": n, "present": false])
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0
            let perm = (attrs[.posixPermissions] as? Int) ?? 0
            let mo = readMachO(p)
            // 真正试一次 spawn：errno 由 BuildRunner 带回来
            let r = BuildRunner.shared.run(executable: p, args: ["--version"], env: [:], timeout: 5)
            var row: [String: Any] = [
                "name": n,
                "present": true,
                "size": size,
                "executable": (perm & 0o111) != 0,
                "magic": mo.magic,
                "mach_o": mo.isMachO,
                "code_signature": mo.hasCodeSignature,
                "cryptid": Int(mo.cryptid),
                "rpaths": mo.rpaths,
                "dylibs": Array(mo.dylibs.prefix(6)),
                "spawn_ok": r.spawnError == nil,
                "spawn_error": r.spawnError ?? "",
                "exit_code": Int(r.exitCode)
            ]
            if let lib = mo.dylibs.first(where: { $0.hasPrefix("@rpath/") }) {
                let rel = String(lib.dropFirst("@rpath/".count))
                let fwPath = Bundle.main.bundlePath + "/Frameworks/" + rel
                row["first_rpath_dylib"] = lib
                row["first_rpath_dylib_exists"] = fm.fileExists(atPath: fwPath)
            }
            rows.append(row)
        }

        let broken = rows.filter { ($0["present"] as? Bool) == true && ($0["spawn_ok"] as? Bool) == false }
        // errno 85 = ENOSYS：不是文件坏了，是越狱 hook 了 posix_spawn 拒绝执行
        let enosys = broken.contains { (($0["spawn_error"] as? String) ?? "").contains("errno 85") }
        var advice = "内置二进制均可执行"
        if enosys {
            advice = "errno 85 = ENOSYS：本机越狱（rootHide / Relaxin）hook 了 posix_spawn，"
                + "拒绝执行 App 容器内的第三方二进制。这不是签名或文件损坏，重装/重签都无效；"
                + "Apple 系统二进制（/usr/bin/plutil 等）仍可执行。"
                + "请改用进程内工具：inject binary_symbols / package / macho / plutil / grep。"
        } else if !broken.isEmpty {
            advice = "有 \(broken.count) 个内置二进制无法 spawn。看每行的 code_signature / mach_o / first_rpath_dylib_exists："
                + "mach_o=false → 文件损坏（不是 Mach-O）；code_signature=false → 重签时被 strip；"
                + "first_rpath_dylib_exists=false → 依赖 framework 缺失（同样报 Bad executable）"
        }

        return [
            "bundle": Bundle.main.bundlePath,
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "sandboxed_container": Bundle.main.bundlePath.contains("/Containers/Bundle/Application/"),
            "binaries": rows,
            "broken_count": broken.count,
            "jailbreak_spawn_blocked": enosys,
            "advice": advice
        ]
    }
}

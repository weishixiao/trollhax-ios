import Foundation

// v6.9.6：崩溃符号化接线——把 CrashCatcher 落盘的裸帧地址（sig_*.txt）变成「模块 + 符号 + 偏移」。
//
// 背景：CrashCatcher 从 v6.2.4 起只在 handler 里写 `地址 - base`（绝不调符号化器，避免二次段错误），
// 于是日志里只有一串十六进制；v6.2.8 写出的 base 是**主镜像加载基址**，但当时没有落 UUID，
// 事后无法确定这份日志对应哪一份二进制/dSYM，也就没法交给 atos 正确符号化。
// 本文件把三段接起来：
//   1. CrashCatcher 写出 `uuid=<LC_UUID> pc=<arm64 pc 寄存器>`（install() 正常上下文预缓存，handler 纯拷贝）
//   2. 本文件解析日志 → 帧地址 − base = 文件内**相对地址**（__TEXT vmaddr 恒为 0，选对切片后即等同于
//      nm/atos 的地址空间）→ 查符号表（优先 dSYM，其次自身二进制）→ 得到函数名 + 偏移
//   3. DiagnoseCrashTool 调用本文件，把结果并进 diagnose.crash 返回
//
// 实现约束：
//   - 只做**纯静态文件解析**（手写 Mach-O / dSYM DWARF 读取，不依赖 MachOKit），
//     这样既能给 CrashCatcher 在后台线程调用，也能脱离 iOS 在桌面单测。
//   - 多线程安全：所有缓存访问走 NSLock（DiagnoseCrashTool 是 async 工具，会并发进来）。
//   - 绝不抛异常、绝不崩溃：任何解析失败都退化成「只有地址」，并把原因写进 notes。

// MARK: - 日志头

/// CrashCatcher 写入的 sig_*.txt 头行 + 裸帧地址。
struct CrashRecord {
    var path: String
    var signal: String?
    var fault: UInt64?
    var base: UInt64?
    var pc: UInt64?
    /// 小写、无 0x 前缀
    var uuid: String?
    var version: String?
    var ish: Bool?
    var timestamp: Date?
    /// 裸帧地址（按日志顺序，0 已剔除）
    var frames: [UInt64]

    var fileName: String { (path as NSString).lastPathComponent }

    /// 解析单行头：`signal SIGSEGV fault=0x... base=0x... pc=0x... uuid=... ver=... ish=0 <ts>`
    /// 分隔符只有空格；`key=value`；信号名是裸 token（CrashCatcher 写的是 "signal SIGSEGV"），
    /// 裸纯数字 token 才是时间戳。未知字段忽略（向后兼容）。已知 token 只取第一次出现的值。
    static func parseHeader(_ line: String) -> CrashRecord {
        var r = CrashRecord(path: "", frames: [])
        for token in line.split(separator: " ", omittingEmptySubsequences: true) {
            guard let eq = token.firstIndex(of: "=") else {
                if token.allSatisfy({ $0.isNumber }), let ts = Int(token) {
                    r.timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
                } else if r.signal == nil {
                    r.signal = String(token)
                }
                continue
            }
            let key = token[token.startIndex..<eq]
            let val = token[token.index(after: eq)...]
            switch key {
            case "signal": if r.signal == nil { r.signal = String(val) }
            case "fault": r.fault = parseHex(val)
            case "base":  r.base = parseHex(val)
            case "pc":    r.pc = parseHex(val)
            case "uuid":  r.uuid = normalizeUUID(String(val))
            case "ver":   r.version = String(val)
            case "ish":   r.ish = (val == "1" || val == "true")
            default: break
            }
        }
        return r
    }

    /// 解析整份日志（UTF-8；截断/乱码行一律跳过）
    static func parse(path: String) -> CrashRecord? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text: text, path: path)
    }

    static func parse(text: String, path: String) -> CrashRecord? {
        let lines = text.components(separatedBy: .newlines)
        guard let headerLine = lines.first else { return nil }
        // 非 sig_ 日志（exc_*.txt 的 Uncaught Exception 格式）没有裸帧行，仍返回头信息供上层判断
        var rec = parseHeader(headerLine)
        rec.path = path
        for raw in lines.dropFirst() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let body = t.hasPrefix("0x") || t.hasPrefix("0X") ? String(t.dropFirst(2)) : t
            guard let v = UInt64(body, radix: 16), v != 0 else { continue }
            rec.frames.append(v)
        }
        return rec
    }

    static func parseHex(_ s: Substring) -> UInt64? {
        var body = s
        if body.hasPrefix("0x") || body.hasPrefix("0X") { body = body.dropFirst(2) }
        return UInt64(body, radix: 16)
    }

    /// "ADF1B0C0-1234-..." → "adf1b0c01234..."（32 位小写 hex，无连字符；非法返回 nil）
    static func normalizeUUID(_ s: String) -> String? {
        let hex = s.lowercased().replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

// MARK: - 符号解析结果

struct SymbolizedFrame {
    var address: UInt64
    var offset: UInt64
    /// 命中的符号（nil = 符号表里没有覆盖该地址的符号）
    var function: String?
    /// 符号内偏移；function 为 nil 时为 nil
    var symbolOffset: UInt64?
    var endAddress: UInt64?
    /// `function + 12`，AI/用户直接可读
    var display: String
    /// dsym / binary / binary-approx / none
    var source: String
    /// 符号地址是「相对 __TEXT」还是「文件偏移」——决定调用方要不要再减一次 __TEXT.fileoff
    var addressKind: String
    var isSymbolStub: Bool
}

struct SymbolicationResult {
    var ok: Bool
    var image: [String: Any]      // uuid / path / arch / text_fileoff / text_vmaddr / slice
    var match: String             // exact / mismatch / missing / unknown
    var frames: [SymbolizedFrame]
    var notes: [String]
}

// MARK: - Mach-O 轻量模型

/// 符号化所需的 Mach-O 事实。全部由 `MachOReader` 从文件字节里直接读出。
struct MachOFacts {
    var sliceOffset: UInt64 = 0
    var arch: String = "unknown"
    var cpuType: Int32 = 0
    var is64: Bool = true
    var uuid: String?
    var textVMAddr: UInt64 = 0
    var textFileOff: UInt64 = 0
    var textSize: UInt64 = 0
    var symtabOffset: UInt64 = 0
    var symtabCount: UInt32 = 0
    var strtabOffset: UInt64 = 0
    var strtabSize: UInt64 = 0
    /// (start, end, name) —— 已排序、已合并 N_FUN 条目对
    var symbols: [(start: UInt64, end: UInt64, name: String)] = []
}

enum MachOReader {
    static let mhMagic64: UInt32 = 0xFEEDFACF
    static let mhMagic64Swapped: UInt32 = 0xCFFAEDFE
    static let fatMagic: UInt32 = 0xCAFEBABE
    static let fatMagic64: UInt32 = 0xCAFEBABF
    static let lcUuid: UInt32 = 0x1B
    static let lcSymtab: UInt32 = 0x2
    static let lcSegment64: UInt32 = 0x19
    static let lcSegment: UInt32 = 0x1

    /// 直接整文件读入（主二进制 + dSYM 都远小于内存上限；读失败返回 nil）。
    static func read(_ path: String) -> (Data, MachOFacts)? {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 32 else { return nil }
        guard var facts = parse(data) else { return nil }
        facts.symbols = parseSymtab(data, facts: facts)
        return (data, facts)
    }

    /// v6.9.6：只读头部 + load commands（主二进制可能 200MB+，install() 时不能整文件 mmap）。
    /// 只取 UUID / __TEXT 段 / LC_SYMTAB 位置，不解析符号表。
    static func header(_ path: String) -> MachOFacts? {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? fh.close() }
        // 4MB 足以覆盖 fat header + 全部 load commands（实测主二进制 sizeofcmds < 100KB）
        guard let data = try? fh.read(upToCount: 4 * 1024 * 1024), data.count >= 32 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> MachOFacts? {
        var f = MachOFacts()
        guard data.count >= 32 else { return nil }
        let magic = be32(data, 0)
        var sliceOffset = 0
        if magic == fatMagic || magic == fatMagic64 {
            let archs = be32(data, 4)
            let entrySize = magic == fatMagic64 ? 32 : 20
            guard archs > 0, archs < 64 else { return nil }
            var chosen = -1
            for i in 0..<Int(archs) {
                let base = 8 + i * entrySize
                guard data.count >= base + entrySize else { break }
                let cpu = be32(data, base)
                let cpusub = be32(data, base + 4)
                let off = magic == fatMagic64 ? be64(data, base + 8) : UInt64(be32(data, base + 8))
                // 优先 arm64e（subtype 2）→ arm64 all(0) → arm64(1)
                let score = (cpu == 0x0100_000C) ? (cpusub == 2 ? 3 : (cpusub == 0 ? 2 : 1)) : 0
                if score > chosen, off < UInt64(data.count) {
                    chosen = score
                    sliceOffset = Int(off)
                }
            }
            guard chosen > 0 else { return nil }
        }
        guard data.count >= sliceOffset + 32 else { return nil }
        let sliceMagic = be32(data, sliceOffset)
        guard sliceMagic == mhMagic64 || sliceMagic == mhMagic64Swapped else { return nil }
        f.sliceOffset = UInt64(sliceOffset)
        f.is64 = true

        let ncmds = le32(data, sliceOffset + 16)
        let sizeofcmds = le32(data, sliceOffset + 20)
        f.cpuType = Int32(bitPattern: le32(data, sliceOffset + 4))
        f.arch = f.cpuType == 0x0100_000C ? "arm64" : "cpu\(f.cpuType)"
        var cursor = sliceOffset + 32
        let end = min(cursor + Int(sizeofcmds), data.count)
        var remain = Int(ncmds)
        // __TEXT 的 vmaddr 可能为 0（iOS 主可执行恒为 0），旧实现用 `== 0` 当"未设置"标志，
        // 结果 __TEXT 赋值成功后 __DATA 又把 fileoff 覆盖成它的值 → 地址换算全错。
        var sawText = false
        while cursor + 8 <= end, remain > 0 {
            let cmd = le32(data, cursor)
            let cmdsize = Int(le32(data, cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= end else { break }
            switch cmd {
            case lcUuid:
                if cmdsize >= 24 {
                    var hex = ""
                    for i in 0..<16 {
                        hex += String(format: "%02x", data[cursor + 8 + i])
                    }
                    f.uuid = hex
                }
            case lcSymtab:
                if cmdsize >= 24 {
                    // 这些 fileoff 都是**相对切片起点**的（fat 包里每个 slice 各自编号），
                    // 统一加 sliceOffset 变成整文件绝对偏移，后面解析才不用再记着这件事。
                    f.symtabOffset = UInt64(sliceOffset) + UInt64(le32(data, cursor + 8))
                    f.symtabCount = le32(data, cursor + 12)
                    f.strtabOffset = UInt64(sliceOffset) + UInt64(le32(data, cursor + 16))
                    f.strtabSize = UInt64(le32(data, cursor + 20))
                }
            case lcSegment64:
                if cmdsize >= 72, !sawText {
                    // 真正的 __TEXT 段（vmaddr 恒为 0）；__PAGEZERO 也是首个 segment，
                    // 但它的 fileoff/filesize 都是 0，直接用首条会把地址换算基线钉在 0。
                    guard readCString(data, from: cursor + 8, limit: min(cursor + 24, data.count)) == "__TEXT" else { break }
                    let vmaddr = le64(data, cursor + 24)
                    let fileoff = le64(data, cursor + 40)
                    sawText = true
                    f.textVMAddr = vmaddr
                    f.textFileOff = fileoff
                    let firstSect = cursor + 72
                    if cmdsize >= 72 + 80 {
                        f.textSize = le64(data, firstSect + 40)   // section_64.size（首个 __text）
                    }
                }
            case lcSegment:
                if cmdsize >= 56, !sawText {
                    sawText = true
                    f.textVMAddr = UInt64(le32(data, cursor + 24))
                    f.textFileOff = UInt64(le32(data, cursor + 32))
                }
            default:
                break
            }
            cursor += cmdsize
            remain -= 1
        }
        guard f.uuid != nil || f.symtabCount > 0 else { return nil }
        return f
    }

    /// nlist_64 表 → 符号区间。普通符号的结束地址由**下一个符号的起始地址**界定，
    /// 遇到 N_FUN 调试条目（dSYM 里每个函数成对出现）优先用其 size 定界。
    static func parseSymtab(_ data: Data, facts f: MachOFacts) -> [(start: UInt64, end: UInt64, name: String)] {
        guard f.symtabCount > 0, f.symtabOffset > 0, f.strtabOffset > 0 else { return [] }
        let entrySize = 16
        let tableEnd = f.symtabOffset + UInt64(f.symtabCount) * UInt64(entrySize)
        guard tableEnd <= UInt64(data.count), f.strtabOffset < UInt64(data.count) else { return [] }
        let strEnd = min(f.strtabOffset + max(f.strtabSize, 1), UInt64(data.count))

        var raw: [(start: UInt64, size: UInt64, name: String)] = []
        var pendingFun: (name: String, start: UInt64)?
        for i in 0..<Int(f.symtabCount) {
            let off = Int(f.symtabOffset) + i * entrySize
            guard off + entrySize <= data.count else { break }
            let strx = le32(data, off)
            let type = data[off + 4]
            let sect = data[off + 5]
            let desc = le16(data, off + 6)
            let value = le64(data, off + 8)
            guard strx != 0 else {
                // N_FUN 的结束条目 strx=0，size 落在 value 字段
                if let p = pendingFun, value > 0 {
                    raw.append((p.start, value, p.name))
                    pendingFun = nil
                }
                continue
            }
            let nameOff = Int(f.strtabOffset) + Int(strx)
            guard nameOff >= 0, UInt64(nameOff) < strEnd else { continue }
            let name = readCString(data, from: nameOff, limit: Int(strEnd))
            guard !name.isEmpty else { continue }
            let nType = type & 0x0E
            if nType == 0x0E {   // N_FUN
                // st_value 为 __TEXT 相对地址（vmaddr 空间）；文件偏移 = value - textVMAddr + textFileOff
                let n = stripLeadingUnderscore(name.components(separatedBy: ":").first ?? name)
                if n.isEmpty {
                    pendingFun = nil
                    continue
                }
                pendingFun = (n, value)
                // N_FUN 的 size 有两种落法：n_desc（旧 as 编译器）或紧随其后的空名条目（ld64 默认）。
                // n_desc 是 16 位混合字段，低 8 位才是 size；这里两种都收，size 为 0 时留给
                // 后面的「下一个符号起点」兜底。
                if desc > 0 {
                    raw.append((value, UInt64(desc), n))
                    pendingFun = nil
                }
            } else if nType == 0x02 {   // N_SECT
                guard value != 0, sect != 0 else { continue }
                let n = stripLeadingUnderscore(name)
                if n.isEmpty || n.hasPrefix("ltmp") || n.hasPrefix("loh") { continue }
                raw.append((value, 0, n))
            } else {
                continue
            }
        }
        // 无 size 的符号用下一个符号起点定界；再合并同名重叠区间
        let sorted = raw.sorted { $0.start < $1.start }
        var out: [(start: UInt64, end: UInt64, name: String)] = []
        out.reserveCapacity(sorted.count)
        for (idx, item) in sorted.enumerated() {
            var endAddr = item.start + item.size
            if item.size == 0 {
                // 找下一个更大的起点
                var nextStart = item.start + 1
                var j = idx + 1
                while j < sorted.count {
                    if sorted[j].start > item.start { nextStart = sorted[j].start; break }
                    j += 1
                }
                endAddr = nextStart
            }
            if endAddr <= item.start { endAddr = item.start + 1 }
            out.append((item.start, endAddr, item.name))
        }
        return out
    }

    static func stripLeadingUnderscore(_ s: String) -> String {
        s.hasPrefix("_") ? String(s.dropFirst()) : s
    }

    static func readCString(_ data: Data, from offset: Int, limit: Int) -> String {
        var bytes: [UInt8] = []
        var i = offset
        while i < limit && i < data.count && bytes.count < 512 {
            let b = data[i]
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func le16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }
    static func le32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    static func le64(_ d: Data, _ o: Int) -> UInt64 {
        UInt64(le32(d, o)) | (UInt64(le32(d, o + 4)) << 32)
    }
    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }
    static func be64(_ d: Data, _ o: Int) -> UInt64 {
        (UInt64(be32(d, o)) << 32) | UInt64(be32(d, o + 4))
    }
}

// MARK: - 符号化器

/// 线程安全的 Mach-O 缓存（key: 规范化路径 + mtime/size，避免文件被替换后命中旧符号表）
private final class MachOCache {
    static let shared = MachOCache()
    private var store: [String: (stamp: String, facts: MachOFacts)] = [:]
    private let lock = NSLock()

    func facts(for path: String) -> MachOFacts? {
        let stamp = Self.stamp(path)
        lock.lock()
        if let hit = store[path], hit.stamp == stamp {
            lock.unlock()
            return hit.facts
        }
        lock.unlock()
        guard let (_, facts) = MachOReader.read(path) else {
            lock.lock(); store[path] = (stamp, MachOFacts()); lock.unlock()
            return nil
        }
        lock.lock()
        if store.count > 16 { store.removeAll() }
        store[path] = (stamp, facts)
        lock.unlock()
        return facts
    }

    /// 清空缓存（文件被替换 / 重新安装后调用）
    func removeAll() {
        lock.lock()
        store.removeAll()
        lock.unlock()
    }

    private static func stamp(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.stringValue ?? "?"
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(mtime)"
    }
}

enum CrashSymbolicator {
    /// 主可执行文件路径；`ownerName` 为 nil 时即 TrollHax 自身。
    /// 注意：CrashCatcher 的 basename 已被 SwiftPM 改写成 TrollHax（target 名），不能用 processName。
    static var mainExecutablePath: String {
        Bundle.main.executablePath ?? "/proc/self/exe"
    }

    // MARK: 入口

    /// 符号化一份 sig_*.txt。
    /// - Parameters:
    ///   - record: 已解析的崩溃记录（不带则按 path 现读）
    ///   - dSYMPaths: 候选 dSYM 路径（可传 .app.dSYM 目录或其中 DWARF 文件）
    ///   - binaryPath: 主二进制；nil → 自身
    ///   - limit: 最多返回多少帧（默认全给，最多 64）
    static func symbolicate(record: CrashRecord,
                            dsymPaths: [String] = [],
                            binaryPath: String? = nil,
                            limit: Int = 64) -> SymbolicationResult {
        var notes: [String] = []
        let binPath = binaryPath ?? mainExecutablePath
        let binFacts = MachOCache.shared.facts(for: binPath)
        var image: [String: Any] = ["path": binPath]
        if let b = binFacts {
            if let u = b.uuid { image["uuid"] = formattedUUID(u) }
            image["arch"] = b.arch
            image["text_fileoff"] = b.textFileOff
            image["text_vmaddr"] = b.textVMAddr
            image["text_size"] = b.textSize
        } else {
            notes.append("无法解析主二进制 Mach-O：\(binPath)")
        }

        // UUID 比对
        var match = "unknown"
        if let logUUID = record.uuid {
            if let b = binFacts, let bu = b.uuid {
                match = (logUUID == bu) ? "exact" : "mismatch"
                if match == "mismatch" {
                    notes.append("日志 UUID \(formattedUUID(logUUID)) 与当前二进制 \(formattedUUID(bu)) 不一致——"
                                 + "这不是当前安装版本产生的日志，符号只能给出近似位置")
                }
            } else {
                notes.append("日志记录了 UUID 但当前二进制读不到 LC_UUID")
            }
        } else {
            notes.append("日志没有 uuid 字段（v6.9.6 之前写入的旧日志），无法确认与当前二进制是否同一构建")
        }

        guard let recBase = record.base, recBase != 0 else {
            return SymbolicationResult(ok: false, image: image, match: match, frames: [],
                                       notes: notes + ["日志缺少 base 字段，无法换算相对地址"])
        }

        // 选符号源：dSYM（UUID 精确匹配）优先，退化到二进制自身
        var source = "none"
        var facts: MachOFacts?
        var symbolStub = false

        for candidate in dsymPaths {
            let dwarf = resolveDWARF(candidate)
            guard let d = dwarf else { continue }
            guard let f = MachOCache.shared.facts(for: d), !f.symbols.isEmpty else { continue }
            if let logUUID = record.uuid, let du = f.uuid, du != logUUID {
                notes.append("dSYM \(d) UUID 与日志不符，跳过")
                continue
            }
            facts = f
            source = "dsym"
            image["dsym_path"] = d
            if let du = f.uuid { image["dsym_uuid"] = formattedUUID(du) }
            break
        }
        if facts == nil, let b = binFacts {
            facts = b
            source = "binary"
            if b.symbols.isEmpty {
                notes.append("当前二进制没有符号表（已 strip），只能按地址给出占位名；"
                             + "提供同 UUID 的 dSYM/app.dSYM 后可解析出函数名")
            }
        }
        // 兜底：dyld 共享缓存里的系统模块无独立文件，符号只能按地址
        if facts == nil { symbolStub = true }

        let textFileOff = facts?.textFileOff ?? binFacts?.textFileOff ?? 0
        let textVMAddr = facts?.textVMAddr ?? binFacts?.textVMAddr ?? 0
        let addressKind = "text_relative"

        var frames: [SymbolizedFrame] = []
        if let pc = record.pc, pc > 0 {
            image["pc"] = hex(pc)
            image["pc_panel"] = "arm64 信号上下文 pc 寄存器（GPR/PC 面板），同次崩溃的 frame0 通常在同一函数内"
        }
        for addr in record.frames.prefix(max(0, limit)) {
            let rel = addr >= recBase ? addr - recBase : 0
            // 统一到符号表的地址空间：__TEXT vmaddr 恒为 0 → 符号表地址 = 文件偏移 − __TEXT fileoff
            let symAddr = rel >= textFileOff ? rel - textFileOff : rel
            var hit: (start: UInt64, end: UInt64, name: String)?
            if let list = facts?.symbols, !list.isEmpty {
                hit = lookup(list, symAddr)
                // dSYM 里偶尔混有其他切片的符号，偏差一次 __TEXT 偏移也对不上时再试一次
                if hit == nil && symAddr >= textVMAddr {
                    hit = lookup(list, symAddr - textVMAddr)
                }
            }
            var f = SymbolizedFrame(address: addr, offset: rel, function: nil, symbolOffset: nil,
                                    endAddress: nil, display: "\(hex(addr)) (base+\(hex(rel)))",
                                    source: source, addressKind: addressKind, isSymbolStub: symbolStub)
            if let h = hit {
                f.function = h.name
                f.symbolOffset = symAddr >= h.start ? symAddr - h.start : 0
                f.endAddress = h.end
                f.display = "\(h.name) + \(f.symbolOffset ?? 0)"
            }
            frames.append(f)
        }

        // 没有符号名时仍给出可用建议
        if frames.allSatisfy({ $0.function == nil }) && !frames.isEmpty {
            if source == "binary" {
                notes.append("符号表未覆盖这些地址：可能在未导出函数内（常见于 -x 编译）或地址属于系统库")
            }
            notes.append("可执行 `macho load path:<binary>` 复核 UUID；`shell.exec nm -a <binary>` 查全量符号")
        }

        let ok = frames.contains { $0.function != nil }
        return SymbolicationResult(ok: ok, image: image, match: match, frames: frames, notes: notes)
    }

    /// 便捷：从日志路径直接符号化
    static func symbolicate(logPath: String,
                            dsymPaths: [String] = [],
                            binaryPath: String? = nil,
                            limit: Int = 64) -> SymbolicationResult? {
        guard let rec = CrashRecord.parse(path: logPath) else { return nil }
        return symbolicate(record: rec, dsymPaths: dsymPaths, binaryPath: binaryPath, limit: limit)
    }

    /// 崩溃当次构造崩溃记录并落盘（CrashCatcher 用）。不抛异常；失败返回 nil。
    /// - 头行格式与 `CrashRecord.parseHeader` 约定一致
    static func writeRecord(signal: String,
                            fault: UInt64,
                            base: UInt64,
                            pc: UInt64,
                            uuid: String?,
                            version: String?,
                            ish: Bool?,
                            frames: [UInt64],
                            into dir: URL,
                            prefix: String = "sig",
                            timestamp: Int = Int(Date().timeIntervalSince1970)) -> String? {
        var head = "signal \(signal) fault=0x\(String(fault, radix: 16)) base=0x\(String(base, radix: 16))"
        if pc != 0 { head += " pc=0x\(String(pc, radix: 16))" }
        if let u = uuid, let n = CrashRecord.normalizeUUID(u) { head += " uuid=\(n)" }
        if let v = version { head += " ver=\(v)" }
        if let i = ish { head += " ish=\(i ? 1 : 0)" }
        head += " \(timestamp)"
        var body = head
        for a in frames where a != 0 { body += "\n0x" + String(a, radix: 16) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(prefix)_\(timestamp).txt").path
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    // MARK: 内部

    /// 在按起点排序的符号表里找覆盖 addr 的符号（返回起点 ≤ addr 且最靠后的那个）
    static func lookup(_ list: [(start: UInt64, end: UInt64, name: String)], _ addr: UInt64) -> (start: UInt64, end: UInt64, name: String)? {
        var lo = 0
        var hi = list.count - 1
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if list[mid].start <= addr {
                best = mid
                lo = mid + 1
            } else {
                if mid == 0 { break }
                hi = mid - 1
            }
        }
        guard let idx = best else { return nil }
        // 允许落在符号尾部一点点（编译器尾调用 / 对齐填充）
        let s = list[idx]
        // 尾部容差 16KB 覆盖编译器尾调用对齐填充；再远就属于无符号区间
        if addr < s.end || (addr - s.start) < 0x4000 { return s }
        return nil
    }

    /// `.app.dSYM` / `Contents/Resources/DWARF/<name>` / 直接 DWARF 文件 → DWARF 文件路径
    static func resolveDWARF(_ path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return path }
        let dwarfDir = (path as NSString).appendingPathComponent("Contents/Resources/DWARF")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dwarfDir) else { return nil }
        let pick = files.first(where: { $0.contains("TrollHax") }) ?? files.first
        guard let p = pick else { return nil }
        return (dwarfDir as NSString).appendingPathComponent(p)
    }

    static func formattedUUID(_ hex: String) -> String {
        let h = hex.uppercased().replacingOccurrences(of: "-", with: "")
        guard h.count == 32 else { return h }
        let idx = [8, 12, 16, 20]
        var out = ""
        for (i, ch) in h.enumerated() {
            if idx.contains(i) { out += "-" }
            out.append(ch)
        }
        return out
    }

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    // MARK: - v6.6.27 旧接口兼容层
    //
    // 远端 main 上早已有本文件的一个轻量版本（仅 dSYM、静态全局状态），当时没有调用方。
    // v6.9.6 用完整实现取代它时保留这几个入口，避免外部脚本/后续代码按旧签名调用而编译失败。
    // 所有旧入口都转调上面的无状态实现，不再持有静态可变状态（旧的 index/textVMAddr 是全局可变的，
    // 多线程并发符号化会互相污染）。

    /// 旧名：载入 dSYM 是否可用（现在改为即时读取，故等价于"该路径能解析出符号"）
    @discardableResult
    static func load(dsymExecutable path: String) -> Bool {
        guard let dwarf = resolveDWARF(path), let facts = MachOCache.shared.facts(for: dwarf) else { return false }
        return !facts.symbols.isEmpty
    }

    /// 旧名：单帧符号化。`runtimeBase` 即日志里的 base=
    static func symbolicate(frame: UInt64, runtimeBase: UInt64) -> String? {
        let rec = CrashRecord(path: "", signal: nil, fault: nil, base: runtimeBase, pc: nil,
                              uuid: nil, version: nil, ish: nil, timestamp: nil, frames: [frame])
        let res = symbolicate(record: rec, limit: 1)
        guard let f = res.frames.first, f.function != nil else { return nil }
        return f.display
    }

    /// 旧名：dSYM UUID 是否与二进制一致（大小写不敏感）
    static func matches(dsymPath: String, binaryUUID: String) -> Bool {
        guard let dwarf = resolveDWARF(dsymPath),
              let f = MachOCache.shared.facts(for: dwarf), let du = f.uuid else { return false }
        return du.lowercased() == binaryUUID.lowercased()
    }

    /// 旧名：清空缓存（现在是线程安全缓存，清空即丢表，下次按需重读）
    static func reset() {
        MachOCache.shared.removeAll()
    }
}

// MARK: - 与工具层对接的字典形态

extension SymbolicationResult {
    /// 供 DiagnoseCrashTool 直接塞进 JSON 返回
    func asJSON() -> [String: Any] {
        var out: [String: Any] = [
            "ok": ok,
            "uuid_match": match,
            "image": image,
            "notes": notes
        ]
        out["frames"] = frames.map { f -> [String: Any] in
            var d: [String: Any] = [
                "address": SymbolicatedHelpers.hex(f.address),
                "offset": SymbolicatedHelpers.hex(f.offset),
                "display": f.display,
                "source": f.source,
                "address_kind": f.addressKind
            ]
            if let fn = f.function {
                d["function"] = fn
                d["symbol_offset"] = f.symbolOffset ?? 0
            }
            if let e = f.endAddress { d["symbol_end"] = SymbolicatedHelpers.hex(e) }
            return d
        }
        return out
    }
}

enum SymbolicatedHelpers {
    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
}

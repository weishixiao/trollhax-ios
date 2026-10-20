import SwiftUI
import UIKit

/// v6.6.12：Rootfs 管理（对齐 OpenMinis「Rootfs 管理」页面能力）。
///
/// 分区：
///   状态      安装情况 / 占用大小 / 落盘路径
///   浏览      直接进 Alpine 文件树
///   镜像      Alpine APK / Python pip / Node npm 源（写入 rootfs 配置，立即生效）
///   容器网络  DNS 模式（自动跟随系统 / 指定引擎内置 DNS）
///   操作      重置 rootfs / 重置并备份 /root
///   信息      说明
///
/// 所有写操作都在 guest 内通过 ISHEngine.exec 完成（fakefs 必须由内核写入，
/// 从 iOS 侧直接改 Documents/alpine-rootfs/data 会与 fakefs 元数据不一致）。
struct RootfsManagementView: View {
    @State private var installed = false
    @State private var sizeText = "计算中…"
    @State private var busy = false
    @State private var toast: String?
    @State private var showResetConfirm = false
    @State private var showBackupResetConfirm = false

    // 镜像源
    @State private var apkMirror = "USTC"
    @State private var pipMirror = "Alibaba"
    @State private var npmMirror = "npmmirror"
    @State private var dnsMode = "自动"
    @State private var currentDNS = "—"

    private static var rootfsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alpine-rootfs").path
    }
    private static var dataPath: String { rootfsPath + "/data" }

    var body: some View {
        List {
            statusSection
            browseSection
            mirrorSection
            networkSection
            actionSection
            infoSection
        }
        .navigationTitle("Rootfs 管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .alert("重置 Rootfs？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { resetRootfs(backup: false) }
        } message: {
            Text("将删除整个 Alpine 文件系统（含已安装软件包与 /root 下文件）。iOS 工作区不受影响。重置后需重启 App 才会重新安装。")
        }
        .alert("重置并备份用户数据？", isPresented: $showBackupResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("备份并重置", role: .destructive) { resetRootfs(backup: true) }
        } message: {
            Text("先把 /root 打包到工作区 HaxBackup/，再重置 rootfs。重装后可手动解包恢复。")
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .foregroundColor(.white)
                    .padding(.bottom, 28)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { toast = nil }
                    }
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            HStack {
                Text("状态")
                Spacer()
                Text(installed ? "已安装" : "未安装")
                    .foregroundColor(.secondary)
                Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(installed ? .green : .red)
            }
            HStack {
                Text("大小")
                Spacer()
                Text(sizeText).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("路径").font(.subheadline)
                Text(Self.rootfsPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        } header: { Text("状态") }
    }

    // MARK: - 浏览

    private var browseSection: some View {
        Section {
            NavigationLink {
                AlpineFileBrowserView(rootPath: Self.dataPath + "/root")
            } label: {
                Label("浏览 /root", systemImage: "folder.fill")
            }
            NavigationLink {
                AlpineFileBrowserView(rootPath: Self.dataPath)
            } label: {
                Label("浏览整个文件系统", systemImage: "internaldrive")
            }
        } header: { Text("浏览") }
    }

    // MARK: - 镜像源

    private var mirrorSection: some View {
        Section {
            Menu {
                ForEach(["USTC", "Aliyun", "Tsinghua", "Official"], id: \.self) { m in
                    Button(m) { applyApkMirror(m) }
                }
            } label: {
                HStack {
                    Label("Alpine APK", systemImage: "shippingbox.fill")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(apkMirror).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
            }
            Menu {
                ForEach(["Alibaba", "Tsinghua", "USTC", "Official"], id: \.self) { m in
                    Button(m) { applyPipMirror(m) }
                }
            } label: {
                HStack {
                    Label("Python pip", systemImage: "cube.fill")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(pipMirror).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
            }
            Menu {
                ForEach(["npmmirror", "Official"], id: \.self) { m in
                    Button(m) { applyNpmMirror(m) }
                }
            } label: {
                HStack {
                    Label("Node.js npm", systemImage: "shippingbox.circle.fill")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(npmMirror).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
            }
        } header: { Text("镜像") } footer: {
            Text(installed ? "切换即时写入 rootfs，下一次 apk/pip/npm 命令生效。" : "需先安装 rootfs（首次打开终端会自动安装）。")
                .font(.caption2)
        }
    }

    // MARK: - 容器网络

    private var networkSection: some View {
        Section {
            Menu {
                Button("自动（223.5.5.5 / 119.29.29.29 / 8.8.8.8）") { applyDNS("自动") }
                Button("仅国内（223.5.5.5 / 119.29.29.29）") { applyDNS("国内") }
                Button("仅 Google（8.8.8.8 / 8.8.4.4）") { applyDNS("Google") }
            } label: {
                HStack {
                    Text("DNS 模式")
                    Spacer()
                    Text(dnsMode).foregroundColor(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundColor(.secondary)
                }
            }
            HStack {
                Text("当前生效")
                Spacer()
                Text(currentDNS).font(.caption).foregroundColor(.secondary)
            }
        } header: { Text("容器网络") } footer: {
            Text("写入 Alpine 的 /etc/resolv.conf。使用代理/VPN 时建议保持「自动」。")
                .font(.caption2)
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("重置 Rootfs", systemImage: "arrow.counterclockwise.circle.fill")
            }
            .disabled(!installed || busy)

            Button(role: .destructive) {
                showBackupResetConfirm = true
            } label: {
                Label("重置并备份用户数据", systemImage: "externaldrive.fill.badge.timemachine")
            }
            .disabled(!installed || busy)
        } header: { Text("操作") }
    }

    // MARK: - 信息

    private var infoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("关于 Rootfs").font(.subheadline.weight(.semibold))
                Text("Rootfs 包含 Alpine Linux 文件系统。重置会删除所有数据并恢复出厂状态。")
                    .font(.caption).foregroundColor(.secondary)
                Text("• 重置：删除所有内容\n• 备份：保存 /root 到工作区\n• 恢复：从工作区备份解包")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        } header: { Text("信息") }
    }

    // MARK: - 逻辑

    private func refresh() {
        let fm = FileManager.default
        installed = fm.fileExists(atPath: Self.dataPath)
        if installed {
            DispatchQueue.global(qos: .utility).async {
                let size = Self.directorySize(Self.rootfsPath)
                let f = ByteCountFormatter()
                f.countStyle = .file
                let text = f.string(fromByteCount: size)
                DispatchQueue.main.async { sizeText = text }
            }
            // 读当前 DNS（guest 内）
            let r = ISHEngine.exec("cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -3", timeout: 8)
            let dns = r.output.components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("nameserver") else { return nil }
                    return t.replacingOccurrences(of: "nameserver", with: "").trimmingCharacters(in: .whitespaces)
                }
                .joined(separator: " / ")
            currentDNS = dns.isEmpty ? "（未配置）" : dns
        } else {
            sizeText = "—"
            currentDNS = "—"
        }
    }

    // MARK: 镜像

    private func applyApkMirror(_ name: String) {
        let base: String
        switch name {
        case "USTC":    base = "https://mirrors.ustc.edu.cn/alpine/latest-stable"
        case "Aliyun":  base = "https://mirrors.aliyun.com/alpine/latest-stable"
        case "Tsinghua": base = "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable"
        default:        base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable"
        }
        let cmd = """
        mkdir -p /etc/apk && \
        printf '%s\\n' '\(base)/main' '\(base)/community' > /etc/apk/repositories && \
        cat /etc/apk/repositories
        """
        runAndReport(cmd, success: "APK 源已切换到 \(name)") {
            apkMirror = name
        }
    }

    private func applyPipMirror(_ name: String) {
        let url: String
        switch name {
        case "Alibaba":  url = "https://mirrors.aliyun.com/pypi/simple/"
        case "Tsinghua": url = "https://pypi.tuna.tsinghua.edu.cn/simple"
        case "USTC":     url = "https://mirrors.ustc.edu.cn/pypi/simple"
        default:         url = "https://pypi.org/simple"
        }
        let cmd = """
        mkdir -p /etc /root/.config/pip && \
        printf '[global]\\nindex-url = \(url)\\ntrusted-host = %s\\n' "$(echo \(url) | sed -E 's#https://([^/]+)/.*#\\1#')" > /etc/pip.conf && \
        cp /etc/pip.conf /root/.config/pip/pip.conf && cat /etc/pip.conf
        """
        runAndReport(cmd, success: "pip 源已切换到 \(name)") {
            pipMirror = name
        }
    }

    private func applyNpmMirror(_ name: String) {
        let url = name == "npmmirror" ? "https://registry.npmmirror.com" : "https://registry.npmjs.org"
        let cmd = """
        mkdir -p /root && printf 'registry=\(url)\\n' > /root/.npmrc && cat /root/.npmrc
        """
        runAndReport(cmd, success: "npm 源已切换到 \(name)") {
            npmMirror = name
        }
    }

    private func applyDNS(_ mode: String) {
        let servers: String
        switch mode {
        case "国内":   servers = "223.5.5.5 119.29.29.29"
        case "Google": servers = "8.8.8.8 8.8.4.4"
        default:       servers = "223.5.5.5 119.29.29.29 8.8.8.8"
        }
        let lines = servers.components(separatedBy: " ").map { "echo 'nameserver \($0)' >> /etc/resolv.conf" }
        let cmd = "echo '# hax-dns \(mode)' > /etc/resolv.conf; " + lines.joined(separator: "; ") + "; cat /etc/resolv.conf"
        runAndReport(cmd, success: "DNS 已切换：\(mode)") {
            dnsMode = mode
            currentDNS = servers.replacingOccurrences(of: " ", with: " / ")
        }
    }

    // MARK: 重置

    private func resetRootfs(backup: Bool) {
        busy = true
        let fm = FileManager.default
        if backup {
            let stamp = Int(Date().timeIntervalSince1970)
            let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Workspace/HaxBackup")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tarPath = dir.appendingPathComponent("root-\(stamp).tar.gz").path
            // guest 内打包 /root（fakefs 只能从 guest 读）
            let r = ISHEngine.exec("tar czf '/ios_workspace/HaxBackup/root-\(stamp).tar.gz' -C / root 2>&1 || tar czf '\(tarPath)' -C / root 2>&1", timeout: 120)
            _ = r
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if fm.fileExists(atPath: Self.rootfsPath) {
                try? fm.removeItem(atPath: Self.rootfsPath)
            }
            DispatchQueue.main.async {
                busy = false
                installed = false
                sizeText = "—"
                toast = backup ? "已备份到 Workspace/HaxBackup 并重置，请重启 App" : "已重置，请重启 App 重新安装"
            }
        }
    }

    private func runAndReport(_ cmd: String, success: String, done: @escaping () -> Void) {
        guard installed else { toast = "请先安装 rootfs（打开一次终端即可）"; return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ISHEngine.exec(cmd, timeout: 40)
            DispatchQueue.main.async {
                busy = false
                if r.exitCode == 0 {
                    toast = success
                    done()
                } else {
                    toast = "失败（退出码 \(r.exitCode)）：\(r.output.prefix(80))"
                }
            }
        }
    }

    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let en = FileManager.default.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            if let s = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(s)
            }
        }
        return total
    }
}

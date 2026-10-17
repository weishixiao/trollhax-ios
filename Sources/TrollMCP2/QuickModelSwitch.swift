import SwiftUI

// MARK: - v6.2.8 快速切换模型（含上游中转站模型列表）
// 动机（用户反馈）：顶栏模型菜单只有已保存的配置名，没有中转站实际提供的各个模型。
// 本面板：①已保存配置点选即切换 ②每个配置可「获取模型」读取该站 /models 列表，
// 点选某个模型即把该配置切到该模型并设为默认 —— 一步到位。

struct QuickModelSwitchSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    @Environment(\.dismiss) private var dismissSheet
    /// configID → 该站上游模型 id 列表
    @State private var upstream: [UUID: [String]] = [:]
    /// 正在请求模型列表的 configID
    @State private var loading: Set<UUID> = []
    /// configID → 错误信息
    @State private var errors: [UUID: String] = [:]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("已保存的配置（点选即切换）")) {
                    ForEach(modelStore.configs) { cfg in
                        Button(action: { switchTo(cfg, model: nil) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cfg.name)
                                        .foregroundColor(.primary)
                                    Text("\(cfg.provider) · \(cfg.model)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if cfg.isDefault {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                Section(header: Text("上游中转站模型"),
                        footer: Text("点「获取模型」读取该站 /models 列表；点某个模型立即把该站切换到它并设为默认。")) {
                    ForEach(modelStore.configs) { cfg in
                        upstreamBlock(cfg)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("快速切换模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismissSheet() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func upstreamBlock(_ cfg: ModelConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(cfg.baseURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if loading.contains(cfg.id) {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button(upstream[cfg.id] == nil ? "获取模型" : "刷新") { fetchModels(cfg) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
            if let err = errors[cfg.id] {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
            if let models = upstream[cfg.id] {
                if models.isEmpty {
                    Text("未返回任何模型")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else {
                    ForEach(Array(models.prefix(200).enumerated()), id: \.offset) { _, m in
                        Button(action: { switchTo(cfg, model: m) }) {
                            HStack {
                                Text(m)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if cfg.model == m {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func fetchModels(_ cfg: ModelConfig) {
        loading.insert(cfg.id)
        errors[cfg.id] = nil
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            loading.remove(cfg.id)
            switch result {
            case .success(let models):
                upstream[cfg.id] = models
                if models.isEmpty {
                    errors[cfg.id] = "该站未返回模型列表"
                }
            case .failure(let err):
                errors[cfg.id] = err
            }
        }
    }

    private func switchTo(_ cfg: ModelConfig, model: String?) {
        var c = cfg
        if let m = model { c.model = m }
        c.isDefault = true
        modelStore.update(c)
        dismissSheet()
    }
}
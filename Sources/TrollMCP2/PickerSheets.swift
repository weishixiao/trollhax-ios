import SwiftUI

// v6.9.15：Coruna 安全盾 / Web 注入功能已按用户要求删除，
// 这两只选择器组件原本放在 CorunaInjectView.swift 里但属于通用 UI，单独保留。
// 若排查确认无调用方，可整文件删除。

// MARK: - App 选择器
struct AppPickerSheet: View {
    let apps: [AppCatalog.AppEntry]
    @Binding var selectedApp: AppCatalog.AppEntry?
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(apps) { app in
                Button(action: {
                    selectedApp = app
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "app").foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(app.name).foregroundColor(.primary)
                            Text(app.bundleId).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if selectedApp?.bundleId == app.bundleId {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("选择目标 App")
            .navigationBarItems(trailing: Button("关闭") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Dylib 选择器
struct DylibPickerSheet: View {
    let dylibs: [String]
    @Binding var selectedDylib: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List(dylibs, id: \.self) { dylib in
                Button(action: {
                    selectedDylib = dylib
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "square.stack.3d").foregroundColor(.purple)
                        Text((dylib as NSString).lastPathComponent).foregroundColor(.primary)
                        Spacer()
                        if selectedDylib == dylib {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("选择 Dylib")
            .navigationBarItems(trailing: Button("关闭") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

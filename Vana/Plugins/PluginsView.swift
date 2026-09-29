import SwiftUI

/// 插件页:每个能整个开关的插件一段——开关、一句话、它自己的入口页、它自己的免责声明。
///
/// 以前用药表占着聊天顶栏的一颗图标、家人档案挂在会话列表顶上。现在它们都属于「健康」这一个
/// 插件,关掉健康,下面的入口和子开关一起收起来。核心(记忆、召回、搜索……)不在这里:
/// 用户关不掉它。
struct PluginsView: View {
    /// 用药表是一张 sheet(详情页那颗「问问 Vana」要回到聊天界面),由聊天那一屏开。
    var openMedications: () -> Void

    @Environment(TenantContext.self) private var tenants
    /// 开关写在 UserDefaults 里,不是这一屏的状态:改完拨一下这个数,让下面重新读。
    @State private var version = 0

    var body: some View {
        Form {
            Section {
                Text("插件是可以整个开关的能力。关掉之后，Vana 不再带上它的规则、工具和数据；数据本身留在本机，重新打开就回来。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            let _ = version
            ForEach(PluginRegistry.togglable, id: \.manifest.id) { plugin in
                section(for: plugin)
            }
        }
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(for plugin: any VanaPlugin) -> some View {
        let id = plugin.manifest.id
        let enabled = EngineSettings.isPluginEnabled(id)
        Section {
            Toggle(isOn: binding(for: id)) {
                Label(plugin.manifest.name, systemImage: plugin.manifest.icon)
            }
            if enabled {
                ForEach(plugin.surfaces.filter(isAvailable)) { surface in
                    surfaceRow(surface)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(plugin.manifest.summary)
                if enabled, let disclaimer = plugin.disclaimer {
                    Text(disclaimer)
                }
            }
        }
    }

    /// 家人档案要成员隔离真的启用了才有(`TenantScope.isolationAvailable`):一个点进去不起作用
    /// 的入口,比没有这个入口糟。
    private func isAvailable(_ surface: PluginSurface) -> Bool {
        surface.id != PluginSurface.family || TenantScope.isolationAvailable
    }

    @ViewBuilder
    private func surfaceRow(_ surface: PluginSurface) -> some View {
        switch surface.id {
        case PluginSurface.medications:
            if let toggle = surface.toggleId {
                Toggle(isOn: binding(for: toggle)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(surface.title)
                        Text(surface.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                openMedications()
            } label: {
                Label("打开\(surface.title)", systemImage: surface.icon)
            }
        case PluginSurface.family:
            NavigationLink {
                TenantListView(context: tenants, onSelect: {})
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(surface.title, systemImage: surface.icon)
                    Text(surface.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { EngineSettings.isPluginEnabled(id) },
            set: { newValue in
                guard let key = EngineSettings.key(forPlugin: id) else { return }
                UserDefaults.standard.set(newValue, forKey: key)
                version += 1
            }
        )
    }
}

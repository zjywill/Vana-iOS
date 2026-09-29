import SwiftUI

/// 插件页:每个能整个开关的插件一行,点进去是它的详情页。
///
/// **一件设置归不归插件,只看一个问题:关掉这个插件,它还有没有意义。** 没有意义的(Apple 健康
/// 授权、每日 check-in、用药表)就在插件自己的页里,关掉插件就一起收起来;还有意义的(模型、
/// 搜索、位置、照片、语音、记忆、后台任务)留在「设置」。核心(记忆、召回、搜索……)不在这里:
/// 用户关不掉它。
struct PluginsView: View {
    /// 用药表是一张 sheet(详情页那颗「问问 Vana」要回到聊天界面),由聊天那一屏开。
    /// nil 时不给这个入口(比如从设置页的配置引导进来,没有聊天那一屏可回)。
    var openMedications: (() -> Void)?

    /// 开关写在 UserDefaults 里,不是这一屏的状态:从详情页回来时拨一下这个数,让状态重新读。
    @State private var version = 0

    var body: some View {
        Form {
            Section {
                let _ = version
                ForEach(PluginRegistry.togglable, id: \.manifest.id) { plugin in
                    NavigationLink {
                        PluginDetailView(plugin: plugin, openMedications: openMedications)
                            .onDisappear { version += 1 }
                    } label: {
                        row(plugin)
                    }
                }
            } footer: {
                Text("插件是可以整个开关的能力。关掉之后，Vana 不再带上它的规则、工具和数据；数据本身留在本机，重新打开就回来。")
            }
        }
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ plugin: any VanaPlugin) -> some View {
        let enabled = EngineSettings.isPluginEnabled(plugin.manifest.id)
        return HStack(spacing: 12) {
            Image(systemName: plugin.manifest.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.manifest.name)
                Text(plugin.manifest.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(enabled ? "已开启" : "已关闭")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 一个插件的详情页:开关、它自己的页面和设置、它自己的免责声明。关着的时候只剩开关和一句说明。
struct PluginDetailView: View {
    let plugin: any VanaPlugin
    var openMedications: (() -> Void)?

    @Environment(TenantContext.self) private var tenants
    @State private var version = 0
    @State private var auth = HealthAuthorizationModel()

    var body: some View {
        let id = plugin.manifest.id
        let enabled = EngineSettings.isPluginEnabled(id)
        Form {
            let _ = version
            Section {
                Toggle(isOn: binding(for: id)) {
                    Label(plugin.manifest.name, systemImage: plugin.manifest.icon)
                }
            } footer: {
                Text(plugin.manifest.summary)
            }

            if enabled {
                ForEach(plugin.surfaces.filter(isAvailable)) { surface in
                    section(for: surface)
                }
            }

            if enabled, let disclaimer = plugin.disclaimer {
                Section {
                    Text(disclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(plugin.manifest.name)
        .navigationBarTitleDisplayMode(.inline)
        .healthAuthorizationAlert(auth)
    }

    /// 家人档案要成员隔离真的启用了才有(`TenantScope.isolationAvailable`):一个点进去不起作用
    /// 的入口,比没有这个入口糟。
    private func isAvailable(_ surface: PluginSurface) -> Bool {
        switch surface.id {
        case PluginSurface.family: TenantScope.isolationAvailable
        // Apple 健康只属于机主;切到家人时这台设备的授权跟他无关。
        case PluginSurface.appleHealth: tenants.current.isOwner
        case PluginSurface.medications: true
        default: true
        }
    }

    /// 插件只说「是什么」(`surface.id`),去哪儿、长什么样由 app 这一层决定。
    @ViewBuilder
    private func section(for surface: PluginSurface) -> some View {
        switch surface.id {
        case PluginSurface.appleHealth:
            AppleHealthSection(auth: auth)
        case PluginSurface.checkIns:
            CheckInSection()
        case PluginSurface.medications:
            Section {
                if let toggle = surface.toggleId {
                    Toggle(isOn: binding(for: toggle)) {
                        Label(surface.title, systemImage: surface.icon)
                    }
                }
                if let openMedications, surface.toggleId.map(EngineSettings.isPluginEnabled) ?? true {
                    Button {
                        openMedications()
                    } label: {
                        Label("打开\(surface.title)", systemImage: "list.bullet.rectangle")
                    }
                }
            } footer: {
                Text(surface.subtitle)
            }
        case PluginSurface.family:
            Section {
                NavigationLink {
                    TenantListView(context: tenants, onSelect: {})
                } label: {
                    Label(surface.title, systemImage: surface.icon)
                }
            } footer: {
                Text(surface.subtitle)
            }
        case PluginSurface.notes:
            Section {
                NavigationLink {
                    NotesView()
                } label: {
                    Label("打开\(surface.title)", systemImage: surface.icon)
                }
            } footer: {
                Text(surface.subtitle)
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
                // check-in 的正文是健康插件写的:开关一动就重排一次,关掉时把已经排上的撤掉。
                if id == PluginIds.health {
                    Task { await CheckInScheduler.reschedule() }
                }
            }
        )
    }
}

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var controller: SidecastController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { controller.settings.isEnabled }, set: { controller.setEnabled($0) })) {
                Text("Sidecast").font(.headline)
            }
            .toggleStyle(.switch)
            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(controller.lastError == nil ? Color.secondary : Color.red)
                .lineLimit(2)

            Divider()

            Text("出力先").font(.caption).foregroundStyle(.secondary)
            Picker("出力先", selection: Binding(get: { controller.settings.hdmiUID }, set: { controller.setHDMI(uid: $0) })) {
                Text("未選択").tag(String?.none)
                ForEach(controller.devices.outputDevices) { d in
                    Text("\(d.name)（\(d.transport)）").tag(Optional(d.uid))
                }
                if let uid = controller.settings.hdmiUID, controller.devices.device(uid: uid) == nil {
                    Text("（未接続）").tag(Optional(uid))
                }
            }
            .labelsHidden()

            HStack {
                Image(systemName: "speaker.wave.1.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(controller.settings.gain) }, set: { controller.setGain(Float($0)) }), in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }

            Divider()

            Text("対象アプリ").font(.caption).foregroundStyle(.secondary)
            if controller.settings.targets.isEmpty {
                Text("未登録").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(controller.settings.targets) { t in
                HStack {
                    Text(t.displayName)
                    Spacer()
                    Button { controller.removeTarget(t) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("削除")
                }
            }
            let candidates = controller.processes.candidates(excluding: controller.settings.targets)
            Menu {
                if candidates.isEmpty {
                    Text("音を出しているアプリがありません")
                } else {
                    ForEach(candidates) { p in
                        Button(p.displayName) { controller.addTarget(p) }
                    }
                }
            } label: {
                Label("音を出しているアプリから追加…", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)

            Divider()

            Button("Sidecast を終了") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { controller.processes.refresh(); controller.devices.refresh() }
    }
}

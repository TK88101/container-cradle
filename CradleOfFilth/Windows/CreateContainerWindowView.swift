import ContainerCore
import SwiftUI

/// 「新建容器」窗口的常量。单实例 `Window`：全局动作、与具体容器无关（同 Volumes/Images）；
/// 单实例避免多份草稿态并存（B 段 §3.2）。
enum CreateContainerWindowScene {
    static let windowID = "create-container"
}

/// 新建容器窗口（Day 16 T9.6，能力 A）。**薄**：校验的唯一判据是 `form.buildSpec()`
/// （core，可测），view 只做呈现分派——把错误红字放到对应字段区域（B 段 §3.4 允许的
/// 「分派」，不是「判断」）；不写 `if name.isEmpty` 这类重复校验。
///
/// ## env 草稿的生命周期（刻意与其余字段不同）
///
/// 明文只允许**瞬态**存在于本窗口的编辑态（上位 §3.6 / codex #18）：每次变更立即
/// `SecretString(value)` 包回 form——form（长寿命）永不含明文 `String`。`SecretString`
/// 不可读回（D2），所以关窗后 env 草稿**无法重建**——重开窗时清掉 form 里的 env 残留，
/// 否则那是一份用户看不见的隐藏状态，会以 duplicate key 之类的方式咬人。
/// name / image / mounts 无密钥，正常经 form 常驻（关窗再开草稿仍在）。
struct CreateContainerWindowView: View {

    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var mountRows: [MountDraft] = []
    @State private var envRows: [EnvDraft] = []

    var body: some View {
        @Bindable var form = model.creationForm
        // 每帧只算一次（simcodex R1）：原先 4 个 fieldErrorText + 1 个 .disabled 各自
        // 重算 `buildSpec()`（含 Regex 构造），同一帧 5 遍纯浪费。算一次往下传。
        let fieldError = liveFieldError

        Form {
            Section {
                TextField(text: $form.name, prompt: Text(verbatim: "my-container")) {
                    Text("Name")
                }
                // 这一句在 `Form` 里看着多余（Form 会把标签关联到控件，实测有名），
                // 但「有没有名字」取决于**祖先里有没有 Form**——换个父容器就整个反过来，
                // 而那是静态判不出、review 也看不出的。显式写死，不赌容器。
                .accessibilityLabel(Text("Name"))
                fieldErrorText(fieldError, at: .name)

                HStack {
                    TextField(
                        text: $form.imageReference,
                        prompt: Text(verbatim: "docker.io/library/nginx:latest")
                    ) {
                        Text("Image")
                    }
                    .accessibilityLabel(Text("Image"))
                    imageMenu
                }
                fieldErrorText(fieldError, at: .image)
            }

            Section("Volume Mounts") {
                mountRowsList
                Button("Add Mount") { mountRows.append(MountDraft()) }
                fieldErrorText(fieldError, at: .mounts)
            }

            Section("Environment Variables") {
                envRowsList
                Button("Add Variable") { envRows.append(EnvDraft()) }
                fieldErrorText(fieldError, at: .environment)
            }

            submitSection(fieldError: fieldError)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .navigationTitle("New Container")
        .task {
            // 可重建的草稿行照 form 重建；env 不可重建（见类型文档）→ 清残留，保持「行即真相」。
            mountRows = model.creationForm.volumeMounts.map {
                MountDraft(volumeName: $0.volumeName, containerPath: $0.containerPath, readOnly: $0.readOnly)
            }
            envRows = []
            model.creationForm.environment = []

            // 开窗即刷新两个下拉的数据源（B 段 codex #7）：它们平时只在各自管理窗的 `.task`
            // 里刷，用户直接开本窗时可能还是初始空/旧快照——下拉空着又没有任何提示。
            // 两个 store 各自持独立单飞令牌、打不同 XPC 端点，互不相干 → 并行（simcodex R1：
            // 串行是白等一次完整往返，这是开窗首屏的可感知延迟）。
            async let imagesRefresh: Void = model.images.refresh()
            async let volumesRefresh: Void = model.volumes.refresh()
            _ = await (imagesRefresh, volumesRefresh)
        }
        .onChange(of: mountRows) {
            model.creationForm.volumeMounts = mountRows.map {
                VolumeMount(volumeName: $0.volumeName, containerPath: $0.containerPath, readOnly: $0.readOnly)
            }
        }
        .onChange(of: envRows) {
            // 构造点即包 `SecretString`（B 段任务卡）：明文不出本窗口的 @State。
            model.creationForm.environment = envRows.map {
                EnvironmentVariable(key: $0.key, value: SecretString($0.value))
            }
        }
    }

    // MARK: - 行编辑

    private var mountRowsList: some View {
        ForEach($mountRows) { $row in
            HStack {
                Picker("", selection: $row.volumeName) {
                    Text("Select volume…").tag("")
                    // 已选中但列表里已不存在的名字补一个 tag：不补的话 Picker 会显示空白
                    // 并悄悄丢掉选择。合法性仍由 `buildSpec()` / 上游 create 判。
                    if !row.volumeName.isEmpty,
                       !model.volumes.displayedVolumes.contains(where: { $0.name == row.volumeName }) {
                        Text(verbatim: row.volumeName).tag(row.volumeName)
                    }
                    ForEach(model.volumes.displayedVolumes) { volume in
                        Text(verbatim: volume.name).tag(volume.name)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Text("Volume for mount \(mountNumber(of: row))"))
                .frame(maxWidth: 200)

                TextField(text: $row.containerPath, prompt: Text(verbatim: "/data")) {
                    Text("Container path")
                }
                .labelsHidden()
                // 跨行同名读屏分不清是第几行——行标识用**序号**而不是 `containerPath`：
                // 后者是用户正在敲的绑定值，拿它当名字 = 每敲一个字符控件就改名、
                // 读屏反复播报，比同名更吵；且空路径时退化成无区分。
                .accessibilityLabel(Text("Container path for mount \(mountNumber(of: row))"))
                .font(.system(.body, design: .monospaced))

                Toggle("Read-only", isOn: $row.readOnly)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(Text("Read-only for mount \(mountNumber(of: row))"))

                removeButton(label: Text("Remove volume mount \(mountNumber(of: row))")) {
                    mountRows.removeAll { $0.id == row.id }
                }
            }
        }
    }

    private var envRowsList: some View {
        ForEach($envRows) { $row in
            HStack {
                TextField(text: $row.key, prompt: Text(verbatim: "KEY")) {
                    Text("Key")
                }
                .labelsHidden()
                .accessibilityLabel(Text("Key of environment variable \(envNumber(of: row))"))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 200)

                TextField(text: $row.value, prompt: Text(verbatim: "value")) {
                    Text("Value")
                }
                .labelsHidden()
                // 名字里只有序号，**没有 key 也没有 value**：value 是密钥明文草稿（D2），
                // 把它拼进可访问名称等于让读屏念出来、也进 AX 树被任何辅助工具读走。
                .accessibilityLabel(Text("Value of environment variable \(envNumber(of: row))"))
                .font(.system(.body, design: .monospaced))

                removeButton(label: Text("Remove environment variable \(envNumber(of: row))")) {
                    envRows.removeAll { $0.id == row.id }
                }
            }
        }
    }

    /// mount / env 两行共用。`label` **刻意不给默认值**：给了默认值，调用点就能整个不传，
    /// 于是所有行悄悄回落成同一个写死的名字——读屏照样分不清哪一行，而编译绿、守卫也绿。
    /// 「默认值是静默回落的通道」这件事在这里必须被堵死，所以由调用点各自负责取名。
    private func removeButton(label: Text, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help("Remove this row")
    }

    /// 行序号一律 **1-based**：这串数字是念给人听的，中文没有「第 0 个」、日文没有「0 番目」，
    /// 四语译文都按 1-based 写死。用 `firstIndex(where:)` 而不是裸下标——行随时会被删，
    /// 下标越界直接崩；找不到时退回 1 而不是 0，宁可号码重复也不念出一个不存在的序数。
    ///
    /// ★ **前提：行不可重排。** 今天成立（只有 Add / Remove，没有拖拽排序）。
    /// 当初否掉「用 `containerPath` 当行标识」的理由是「名字不能随用户打字抖动」——
    /// 而那条理由同样禁止「用户没动这一行、名字却变了」。加拖拽排序会让位置序号
    /// 正好触犯它：拖动过程中所有行的可访问名称连锁改变，读屏反复播报。
    /// 静态守卫看不出（有 label 就算过），真机判定也看不出（重排后仍然两两不重名）。
    /// → 真要加排序，行标识得换成**随行创建的稳定编号**，不能再用位置。
    private func mountNumber(of row: MountDraft) -> Int {
        (mountRows.firstIndex(where: { $0.id == row.id }) ?? 0) + 1
    }

    private func envNumber(of row: EnvDraft) -> Int {
        (envRows.firstIndex(where: { $0.id == row.id }) ?? 0) + 1
    }

    /// 镜像下拉的名字**只有一个出处**。它同时喂三个地方：`Label` 的文本（→ AXTitle）、
    /// `.accessibilityLabel`（→ AXDescription）、`.help`（→ tooltip）。
    /// 要守的不变式是「两条 AX 信道说同一句话」——写成三个碰巧相等的字面量，
    /// 那就只是纪律；提成一个常量，它才是语法上成立的。
    /// （同一文件里 `removeButton(label:)` 刻意不给默认值，是同一种判断：
    /// 别给静默走偏留通道。）
    private static let imageMenuName: LocalizedStringKey = "Choose from local images"

    /// 本地镜像下拉：只是把 ref 填进文本框（仍可手填任意公开 ref）。
    private var imageMenu: some View {
        Menu {
            ForEach(model.images.displayedImages) { image in
                Button(image.reference.rawValue) {
                    model.creationForm.imageReference = image.reference.rawValue
                }
            }
        } label: {
            // ★ 用 `Label` 而不是裸 `Image`，是为了给这个 Menu 一个**真正的 AXTitle**。
            //
            // 裸 `Image(systemName:)` 时，SF Symbol 的默认名 "Go Down"（描述的是箭头方向，
            // 不是动作）会落进 AXTitle。而 `Menu` 上的 `.accessibilityLabel` 写的是 AXDescription——
            // 真机实测这两条信道**会摇摆**：同一个二进制、同一个窗口，刚点过菜单时读到 Description、
            // 多操作几步后又读到 Title。`.accessibilityHidden(true)` 加在内层 Image 上压不住它。
            //
            // 所以不去赌「哪条信道优先」，而是**让两条信道说同一句话**：
            // `Label` 的文本 → AXTitle，下面的 `.accessibilityLabel` → AXDescription，谁赢都对。
            // `.labelStyle(.iconOnly)` 保证视觉上仍然只有图标，排版不变。
            Label(Self.imageMenuName, systemImage: "chevron.down.circle")
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.iconOnly)
        .fixedSize()
        .disabled(model.images.displayedImages.isEmpty)
        .accessibilityLabel(Text(Self.imageMenuName))
        .help(Self.imageMenuName)
    }

    // MARK: - 提交

    private var isSubmitting: Bool {
        model.creation.phase == .submitting
    }

    private func submitSection(fieldError: ContainerCreationForm.FieldError?) -> some View {
        Section {
            HStack {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                // 「创建」与「创建并启动」是两条失败形态不同的路径（core 的
                // `startAfterCreate` 无默认值，B 段 codex #1）——按钮语义一一对应。
                Button("Create") {
                    Task { await submit(startAfterCreate: false) }
                }

                Button("Create & Start") {
                    Task { await submit(startAfterCreate: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            // disabled 只是体验层（真防线是 store 的单飞拒绝制）。
            .disabled(fieldError != nil || isSubmitting)

            if case .failed(let failure) = model.creation.phase {
                FormErrorText(message: ContainerCreationPresentation.message(for: failure))
            }
        }
    }

    private func submit(startAfterCreate: Bool) async {
        guard case .success(let spec) = model.creationForm.buildSpec() else { return }
        guard await model.creation.submit(spec, startAfterCreate: startAfterCreate) else { return }

        switch model.creation.phase {
        case .succeeded:
            // 成功：刷新列表 → 清草稿 → 关窗（B 段 §3.5 表）。
            await model.containers.refresh()
            model.creationForm.reset()
            model.creation.reset()
            dismiss()

        case .failed(let failure):
            // 部分成功也要刷新（codex #2）：`.startFailed` 时容器**已建成并保留为
            // 已停止**，只在 `.succeeded` 刷新会让列表漏掉它。窗口留着显示失败文案。
            if case .startFailed = failure {
                await model.containers.refresh()
            }

        case .idle, .submitting:
            break
        }
    }

    // MARK: - 校验呈现（分派，不判断）

    private enum ErrorLocation {
        case name
        case image
        case mounts
        case environment
    }

    private var liveFieldError: ContainerCreationForm.FieldError? {
        if case .failure(let error) = model.creationForm.buildSpec() { error } else { nil }
    }

    /// 把首错分派到对应字段区域。穷尽 switch：`FieldError` / `ContainerCreationSpecError`
    /// 新增 case 时这里编译报错（DoD 要求）。
    private func location(of error: ContainerCreationForm.FieldError) -> ErrorLocation {
        switch error {
        case .name:
            .name
        case .image:
            .image
        case .spec(let specError):
            switch specError {
            case .volumeMountPathNotAbsolute, .volumeMountPathContainsColon,
                 .duplicateVolumeMountPath, .invalidVolumeName:
                .mounts
            case .emptyEnvironmentKey, .environmentKeyContainsEquals, .duplicateEnvironmentKey:
                .environment
            }
        }
    }

    @ViewBuilder
    private func fieldErrorText(
        _ error: ContainerCreationForm.FieldError?,
        at location: ErrorLocation
    ) -> some View {
        if let error, self.location(of: error) == location {
            FormErrorText(message: ContainerCreationPresentation.message(for: error))
        }
    }
}

/// volume 挂载行的编辑草稿（view 局部）。无密钥——可以照 form 重建，也随时包回 `VolumeMount`。
private struct MountDraft: Identifiable, Equatable {
    let id = UUID()
    var volumeName = ""
    var containerPath = ""
    var readOnly = false
}

/// env 行的编辑草稿（view 局部）。`value` 是**瞬态明文**（上位 §3.6 允许的唯一形态）：
/// 只活在本窗口 `@State`，每次变更即包回 `SecretString` 进 form，绝不进 log / 快照 / 复制。
private struct EnvDraft: Identifiable, Equatable {
    let id = UUID()
    var key = ""
    var value = ""
}

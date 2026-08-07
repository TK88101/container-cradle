/// **D1 的枢轴。** 签名里只有 domain 类型——`Container` / `ContainerID` / `RuntimeError`。
/// 一个上游类型都没有，所以本 target 零上游依赖，所以 supervisor / reducer / UI 的测试
/// 全都不用链 `ContainerAPIClient`（省掉 15.7 秒的增量构建税，见 `Spikes/SPIKE-RESULT.md`）。
///
/// 这条边界不靠自觉：`D1BoundaryTests` 会扫源码，越界即红灯。
///
/// ## M0 只有三个方法
///
/// `list` / `start` / `stop`——**supervisor 要的就是这三个**。
/// 日志、stats、volume、image 全都往后放（M2/M5）：它们是「顺带的」，
/// 而 supervisor 才是这个 App 存在的理由（CLAUDE.md）。
///
/// ## `start(id:)` 在上游根本不存在
///
/// 上游 `ContainerClient` 只有 `bootstrap` / `stop` / `kill`，**没有 `start(id:)`**（已核实源码）。
/// 「把一个停着的容器拉起来」在上游是一串调用序列（见 `Spikes/SPIKE-RESULT.md`）。
///
/// 这里照样叫 `start`：protocol 表达的是 **domain 的意图**，不是上游 API 的形状。
/// 让 protocol 长得像上游，等于把上游的怪癖泄漏给每一个调用者——那 ACL 就白做了。
/// 那串序列是 M1 live client 的私事。
///
/// ## 起停必须是幂等的
///
/// supervisor 会重复下达 `start`（轮询间隔内容器可能还没起来，下一轮又看见它是 stopped）。
/// 实现方对「已经在跑」必须**静默成功**，不许抛错——官方 CLI 自己就这么短路的。
/// 抛错等于逼每个调用者去区分「真失败」和「本来就在跑」，那是实现方该吸收的复杂度。
public protocol ContainerRuntimeClient: Sendable {

    /// 列出全部容器。
    func list() async throws(RuntimeError) -> [Container]

    /// 拉起容器。已在运行 → 静默成功（幂等）。
    func start(id: ContainerID) async throws(RuntimeError)

    /// 停止容器。已停止 → 静默成功（幂等）。
    func stop(id: ContainerID) async throws(RuntimeError)

    /// 跟随容器日志。**裸流，未脱敏**——D-B'（Day 9 计划）钉死它唯一允许的消费者是
    /// `LogTailer`（`BoundaryScanner` 源码扫描守，见 `D1BoundaryTests`）。app 只看得到
    /// `LogTailer` 产出的 `RedactedLogLine`。
    ///
    /// 建流阶段的错误是 typed（`RuntimeError`）；流**内部**的错误走 `any Error`——
    /// `AsyncThrowingStream` 没有 typed-throws 的版本，这是语言约束（Swift 没有 typed-throws
    /// 的 async sequence），不是偷懒。实现方（ContainerRuntime 的桥）必须只用 `RuntimeError`
    /// （existential）`finish(throwing:)`，让消费方在 `for try await` 的 catch 里拿到的
    /// 已经是 domain 错误，不必自己再兜底把 `any Error` 映射一遍。
    func followLogs(id: ContainerID) async throws(RuntimeError) -> AsyncThrowingStream<LogLine, any Error>

    /// 取一次运行时统计的裸计数器快照。**单发一次 = 一个瞬时样本**——CPU% 需要相邻两次
    /// 样本才能算出速率，那是 `StatsCollector` 的事，这里只负责「问一次，答一次」。
    func stats(id: ContainerID) async throws(RuntimeError) -> ContainerStatsSample

    // MARK: - M5：volume / image 管理（Day 10）

    /// 列出全部 volume。`usedBytes` 由实现方尽力填充（enrichment fail-soft：
    /// 单卷拿不到 = 该卷 nil），**列表本身 fail-closed**——映射不出来就整体抛错，
    /// 不静默丢卷（Day 6 ④ 同款纪律）。
    func listVolumes() async throws(RuntimeError) -> [Volume]

    /// identity-only 查询单卷：**不取 usage**（返回值的 `usedBytes` 恒 nil）。
    ///
    /// 存在与否用 Optional 表达——不存在 = nil，**不是抛错**：not-found 没法从
    /// XPC 错误文本可靠区分，嗅字符串是 R14 同款病。
    ///
    /// 它存在的唯一理由是删除前的 fingerprint 复核（★R2）：带 usage 的
    /// `listVolumes()` 会把「复核 → 删除」的窗口撑成秒/分钟级（多卷 × 5s 超时），
    /// 这条必须是快路径。
    func inspectVolume(named name: String) async throws(RuntimeError) -> Volume?

    /// 删除 volume。语义是**「删除这个 identity」，不是「按名字删」**（★R3）：
    /// 实现方必须在删除前复核 fingerprint（`matchesIdentity`）——同名重建的新卷
    /// 不许被删，即使调用方拿着陈旧的 `Volume` 绕过了 store 的复核，这里是最后防线。
    ///
    /// 吃整个 `Volume` 而非裸 String（D-G）：`Volume` 的构造入口只有运行时的
    /// list 返回与 Fake——「把确认文本当删除目标」在类型上写不出来。
    func deleteVolume(_ target: Volume) async throws(RuntimeError)

    /// 列出镜像。infra 镜像（vminit/builder）已在 ACL 内过滤，domain **看不见**；
    /// `isInfraFilterAuthoritative == false` 表示过滤退化到 stock 默认（config
    /// 没加载成功），UI 必须据此禁用删除（D-C fail-closed）。
    func listImages() async throws(RuntimeError) -> ImageListSnapshot

    /// 删除镜像。实现方删除前必须**重新**确认 infra 过滤（★R3）：非权威 → 拒绝；
    /// reference 命中 infra refs → 拒绝。UI 的禁用只是 UX（旧快照可能过期），
    /// 这里才是防线。
    func deleteImage(reference: ImageRef) async throws(RuntimeError)

    // MARK: - Day 16：创建 / 克隆 / pull / 删除容器（v1.1）

    /// 全新创建一个容器。返回**持久化 identity**（`ContainerID`）。
    ///
    /// 入参 `spec.name` 是**用户提议的合法名**（`ContainerName`），不等于已持久化的 identity
    /// （codex #7）——创建成功后由实现方确认并返回 `ContainerID`，调用方据此起停，
    /// 不靠对名字做字符串手术重构 id。
    ///
    /// **名字唯一性不在这里保证**：`spec` 只自洽（单个 spec 校验），init 看不到别的容器。
    /// 唯一性由调用方在提交前显式存在性检查兜住（`ContainerCreationStore` 用 `list()` 命中即拒，
    /// 靠存在性不嗅错误码——R14）。
    func create(_ spec: ContainerCreationSpec) async throws(RuntimeError) -> ContainerID

    /// clone「以此为模板新建」的预填数据——**纯 domain**（codex #1）。
    ///
    /// app 永不碰上游 `configuration`：桥内从 `snapshot.configuration` 提 image + env
    /// （装进 `SecretString`，**不 reveal**——D2）+ 按挂载类型计数，只让**摘要**上浮成 domain。
    /// 完整配置仍住桥内白名单文件（D1 / ruling 3）。
    func cloneTemplate(for source: ContainerID) async throws(RuntimeError) -> ContainerCloneTemplate

    /// 以 `source` 为模板新建。返回新容器的 `ContainerID`（同 `create(_:)`，honoring codex #7）。
    ///
    /// `envOverride == nil` = 原样克隆：env 从不进 UI、不进 `SecretString`、零上屏（最干净路径）；
    /// 桥内复用源 configuration 的明文 env（**第二密钥路径**，由 clone-禁-log 源码扫描守，codex #6）。
    /// `envOverride != nil` 时经 `serializeEnvironmentForCreate`（D2 唯一 reveal 出口）替换 env。
    func create(
        clonedFrom source: ContainerID,
        name: ContainerName,
        envOverride: [EnvironmentVariable]?
    ) async throws(RuntimeError) -> ContainerID

    /// App 内 pull 一个公开镜像，边拉边报进度。
    ///
    /// **建流阶段** typed（`RuntimeError`）；**流内部** `any Error`——同 `followLogs`
    /// （Swift 没有 typed-throws 的 async 序列，这是语言约束）。桥内只用 `RuntimeError`
    /// existential `finish(throwing:)`，消费方在 `for try await` 的 catch 里拿到的已是 domain 错误。
    /// 进度语义无密钥面（镜像层进度）→ 进 D1 白名单但**不**进 D2 reveal 预算。
    func pullImage(_ reference: ImageRef) async throws(RuntimeError) -> AsyncThrowingStream<PullProgress, any Error>

    /// 删除一个容器（**桥内确定序列**，codex #12）：
    /// 前置 `get(id)` → 不存在直接返回 domain `.containerNotFound`（不经 delete、不嗅错误码）；
    /// 存在则 `delete(force: true)`（删 running 走 server SIGKILL+cleanup）；delete 报错**仅当 runtime
    /// 可达**才 `get` 复核（存在=真失败原样抛，不存在=已删成功当幂等）。
    /// **绝不把「list/get 失败」解读成「容器不存在」**（runtime-down 与 not-found 不可混）。
    func delete(id: ContainerID) async throws(RuntimeError)
}

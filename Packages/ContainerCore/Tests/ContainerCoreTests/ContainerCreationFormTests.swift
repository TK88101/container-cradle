import Testing

@testable import ContainerCore

/// T9.1：`ContainerCreationForm.buildSpec()` 校验矩阵——每类非法输入映射到**按字段定位**的
/// `FieldError`，全合法产出 spec。首错优先（name → image → spec）。
///
/// form 内**零 `.reveal()`**由全局 `D1BoundaryTests.plaintextExitsAreAllRegistered`（扫 `Sources/`）守，
/// 这里不重复——form 不写 reveal 就自动在那条扫描下绿。
@MainActor
@Suite("ContainerCreationForm 校验矩阵")
struct ContainerCreationFormTests {

    private static let secretValue = "sk-not-a-real-key-000"

    private func form(
        name: String = "web",
        image: String = "nginx:latest",
        mounts: [VolumeMount] = [],
        env: [EnvironmentVariable] = []
    ) -> ContainerCreationForm {
        let f = ContainerCreationForm()
        f.name = name
        f.imageReference = image
        f.volumeMounts = mounts
        f.environment = env
        return f
    }

    // MARK: - 成功

    @Test("全合法 → success，spec 携带草稿值")
    func allValid() {
        let f = form(
            mounts: [VolumeMount(volumeName: "data", containerPath: "/data", readOnly: false)],
            env: [EnvironmentVariable(key: "TOKEN", value: SecretString(Self.secretValue))]
        )
        guard case .success(let spec) = f.buildSpec() else {
            Issue.record("expected success")
            return
        }
        #expect(spec.name.value == "web")
        #expect(spec.image.rawValue == "nginx:latest")
        #expect(spec.volumeMounts.count == 1)
        #expect(spec.environment.count == 1)
    }

    // MARK: - name

    @Test("空名 → .name(.empty)")
    func emptyName() {
        #expect(form(name: "").buildSpec() == .failure(.name(.empty)))
    }

    @Test("非法名：空格 / 单字符（<2）/ 首字符非法 → .name(.invalidFormat)")
    func invalidName() {
        #expect(form(name: "a b").buildSpec() == .failure(.name(.invalidFormat)))
        #expect(form(name: "a").buildSpec() == .failure(.name(.invalidFormat)))
        #expect(form(name: "_x").buildSpec() == .failure(.name(.invalidFormat)))
    }

    // MARK: - image

    @Test("空 / 全空白镜像 → .image")
    func emptyImage() {
        #expect(form(image: "").buildSpec() == .failure(.image))
        #expect(form(image: "   ").buildSpec() == .failure(.image))
    }

    // MARK: - spec（volume）

    @Test("非法 volume 名（含 / ）→ .spec(.invalidVolumeName)")
    func invalidVolumeName() {
        let m = [VolumeMount(volumeName: "/etc", containerPath: "/data", readOnly: false)]
        #expect(form(mounts: m).buildSpec() == .failure(.spec(.invalidVolumeName("/etc"))))
    }

    @Test("非绝对容器路径 → .spec(.volumeMountPathNotAbsolute)")
    func nonAbsolutePath() {
        let m = [VolumeMount(volumeName: "data", containerPath: "rel/path", readOnly: false)]
        #expect(form(mounts: m).buildSpec() == .failure(.spec(.volumeMountPathNotAbsolute("rel/path"))))
    }

    @Test("容器路径含冒号 → .spec(.volumeMountPathContainsColon)")
    func pathWithColon() {
        let m = [VolumeMount(volumeName: "data", containerPath: "/data:ro", readOnly: false)]
        #expect(form(mounts: m).buildSpec() == .failure(.spec(.volumeMountPathContainsColon("/data:ro"))))
    }

    @Test("重复容器路径 → .spec(.duplicateVolumeMountPath)")
    func duplicatePath() {
        let m = [
            VolumeMount(volumeName: "a", containerPath: "/data", readOnly: false),
            VolumeMount(volumeName: "b", containerPath: "/data", readOnly: false),
        ]
        #expect(form(mounts: m).buildSpec() == .failure(.spec(.duplicateVolumeMountPath("/data"))))
    }

    // MARK: - spec（env）

    @Test("空 env key → .spec(.emptyEnvironmentKey)")
    func emptyEnvKey() {
        let e = [EnvironmentVariable(key: "", value: SecretString("x"))]
        #expect(form(env: e).buildSpec() == .failure(.spec(.emptyEnvironmentKey)))
    }

    @Test("env key 含 = → .spec(.environmentKeyContainsEquals)")
    func envKeyEquals() {
        let e = [EnvironmentVariable(key: "A=B", value: SecretString("x"))]
        #expect(form(env: e).buildSpec() == .failure(.spec(.environmentKeyContainsEquals("A=B"))))
    }

    @Test("重复 env key → .spec(.duplicateEnvironmentKey)")
    func dupEnvKey() {
        let e = [
            EnvironmentVariable(key: "K", value: SecretString("1")),
            EnvironmentVariable(key: "K", value: SecretString("2")),
        ]
        #expect(form(env: e).buildSpec() == .failure(.spec(.duplicateEnvironmentKey("K"))))
    }

    // MARK: - 首错优先

    @Test("首错优先：name 错排在 image 错之前")
    func firstErrorPriority() {
        // name 空 + image 也空 → 报 name（先），不报 image。
        #expect(form(name: "", image: "").buildSpec() == .failure(.name(.empty)))
    }

    // MARK: - T9.4b：reset()

    /// **逐字段列举断言**，不用「== 新实例」：将来给 form 加第五个字段时，
    /// 「== 新实例」那种写法会因为 `reset()` 忘了清它而**静默继续绿**
    /// （本仓「测试装置把某维度压成常数，那个维度上的 bug 就是隐形的」同源纪律）。
    /// 这里每个字段各一条断言，漏清哪个就红哪条。
    @Test("reset：四个草稿字段逐一回到初始值")
    func resetClearsEveryField() {
        let f = form(
            name: "web",
            image: "nginx:latest",
            mounts: [VolumeMount(volumeName: "data", containerPath: "/data", readOnly: false)],
            env: [EnvironmentVariable(key: "K", value: SecretString(Self.secretValue))]
        )
        // 前置：四个字段都确实是非初始值（否则这条测试什么都没证明）。
        #expect(!f.name.isEmpty)
        #expect(!f.imageReference.isEmpty)
        #expect(!f.volumeMounts.isEmpty)
        #expect(!f.environment.isEmpty)

        f.reset()

        #expect(f.name == "")
        #expect(f.imageReference == "")
        #expect(f.volumeMounts.isEmpty)
        #expect(f.environment.isEmpty)
    }
}

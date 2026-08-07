import ContainerAPIClient
import ContainerCore
import Testing

@testable import ContainerRuntime

/// T4（Day 16）：domain `ContainerCreationSpec` → 上游 create 序列所需的 `Flags.*`（纯映射）。
///
/// 断言的是**字段往返**（id/image/mounts/env 忠实搬过去）与 D2 唯一明文出口
/// `serializeEnvironmentForCreate` 的语义。CreationMapper **不打 XPC、不加载 config**——
/// 那些副作用是 adapter（`LiveContainerRuntimeClient`）的事，这里只做纯结构转换（§3.1）。
///
/// `Flags.Management` 走**全字段 memberwise init**：V2 真机第一轮实崩在「空 `Flags.*()` 让含
/// `@OptionGroup` 的 `Management.dns` 停在未初始化 parsing 态，读它触发 ArgumentParser fatal」。
/// 全字段构造把每个属性钉死（Plan §2 / spike V2）。
@Suite("CreationMapper：ContainerCreationSpec → Flags.*（纯映射）")
struct CreationMapperTests {

    private func makeSpec(
        name: String = "web",
        image: String = "docker.io/library/nginx:latest",
        volumeMounts: [VolumeMount] = [],
        environment: [EnvironmentVariable] = []
    ) throws -> ContainerCreationSpec {
        try ContainerCreationSpec(
            name: try ContainerName(name),
            image: try #require(ImageRef(image)),
            volumeMounts: volumeMounts,
            environment: environment
        )
    }

    // MARK: - id / image / arguments

    @Test("id = 用户提议名；image = ref 原文；arguments 空（依赖镜像自带 entrypoint）")
    func mapsIdentityImageAndArguments() throws {
        let spec = try makeSpec(name: "web", image: "docker.io/library/nginx:latest")

        let inputs = CreationMapper.inputs(for: spec)

        #expect(inputs.id == "web")
        #expect(inputs.image == "docker.io/library/nginx:latest")
        // command/entrypoint 不暴露（non-goal）→ 不传 arguments，依赖镜像自带 entrypoint/cmd。
        #expect(inputs.arguments.isEmpty)
        // id 走 containerConfigFromFlags(id:) 参数，不走 --name → management.name 恒 nil。
        #expect(inputs.management.name == nil)
    }

    // MARK: - volume 挂载 → 上游 --volume 字符串

    @Test("volume 挂载 → `name:dest`（读写）/ `name:dest:ro`（只读），顺序保持")
    func mapsVolumeMountsToUpstreamStrings() throws {
        let spec = try makeSpec(volumeMounts: [
            VolumeMount(volumeName: "data", containerPath: "/var/lib", readOnly: false),
            VolumeMount(volumeName: "cache", containerPath: "/tmp", readOnly: true),
        ])

        let inputs = CreationMapper.inputs(for: spec)

        #expect(inputs.management.volumes == ["data:/var/lib", "cache:/tmp:ro"])
        // volume 走 --volume，不占 --mount（fresh 不建 bind/tmpfs）。
        #expect(inputs.management.mounts.isEmpty)
        #expect(inputs.management.tmpFs.isEmpty)
    }

    @Test("单条只读挂载 = `name:dest:ro`")
    func readOnlyMountAppendsRoOption() throws {
        let mount = VolumeMount(volumeName: "vol", containerPath: "/data", readOnly: true)
        #expect(CreationMapper.volumeArgument(for: mount) == "vol:/data:ro")
    }

    @Test("读写挂载不加选项")
    func readWriteMountHasNoOption() throws {
        let mount = VolumeMount(volumeName: "vol", containerPath: "/data", readOnly: false)
        #expect(CreationMapper.volumeArgument(for: mount) == "vol:/data")
    }

    // MARK: - env → process.env（D2 唯一明文出口）

    @Test("env → process.env 的 `key=value`（明文），顺序保持")
    func mapsEnvironmentToProcessEnv() throws {
        let spec = try makeSpec(environment: [
            EnvironmentVariable(key: "PORT", value: SecretString("8080")),
            EnvironmentVariable(key: "MODE", value: SecretString("prod")),
        ])

        let inputs = CreationMapper.inputs(for: spec)

        #expect(inputs.process.env == ["PORT=8080", "MODE=prod"])
    }

    @Test("serializeEnvironmentForCreate：key=value，值原样（含 base64 尾部的 `=` 不被截断）")
    func serializesEnvironmentVerbatim() {
        let env = [
            EnvironmentVariable(key: "KEY", value: SecretString("aGVsbG8=")),
            EnvironmentVariable(key: "EMPTY", value: SecretString("")),
        ]

        let serialized = CreationMapper.serializeEnvironmentForCreate(env)

        #expect(serialized == ["KEY=aGVsbG8=", "EMPTY="])
    }

    @Test("空 env → process.env 空")
    func emptyEnvironmentMapsToEmpty() throws {
        let inputs = CreationMapper.inputs(for: try makeSpec(environment: []))
        #expect(inputs.process.env.isEmpty)
    }

    // MARK: - Flags 默认值（全字段 init 的固定档）

    @Test("arch = 宿主架构；memory/cpu 不设（上游填默认 ≥200 MiB）；registry=auto")
    func managementUsesHostArchitectureAndDefaults() throws {
        let inputs = CreationMapper.inputs(for: try makeSpec())

        #expect(inputs.management.arch == Arch.hostArchitecture().rawValue)
        #expect(inputs.management.os == "linux")
        #expect(inputs.resource.memory == nil)
        #expect(inputs.resource.cpus == nil)
        #expect(inputs.registry.scheme == "auto")
        // clone/网络/端口是别的能力或 non-goal，fresh 一律空。
        #expect(inputs.management.networks.isEmpty)
        #expect(inputs.management.publishPorts.isEmpty)
        #expect(inputs.management.publishSockets.isEmpty)
    }
}

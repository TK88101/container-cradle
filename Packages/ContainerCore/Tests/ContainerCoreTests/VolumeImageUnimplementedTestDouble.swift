import ContainerCore

/// 测试替身的「未被本用例测的运行时方法」默认 stub（simplify/reuse panel 双双点名的重复收敛点）。
/// 覆盖 M5（volume/image）**与 Day 16（create/clone/pull/delete 容器）**——名字保留 `VolumeImage…`
/// 是历史遗留（更名列为 simcodex P2），语义已是「替身没实现的都在这里抛 unimplemented」。
///
/// **只对显式 opt-in 这个 marker 的替身生效**：`LiveContainerRuntimeClient` /
/// `FakeContainerRuntimeClient` 不声明它，漏实现照样编译红——
/// 「不给 protocol 默认实现，Live 漏实现必须编译红」的不变式**不受影响**，
/// 这正是当初拒绝在 `ContainerRuntimeClient` 上直接放默认实现的全部理由。
///
/// 将来协议再长方法，只改这一个文件，不再往各替身里各贴一遍。
protocol VolumeImageUnimplementedTestDouble {}

extension ContainerRuntimeClient where Self: VolumeImageUnimplementedTestDouble {

    func listVolumes() throws(RuntimeError) -> [Volume] {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func inspectVolume(named name: String) throws(RuntimeError) -> Volume? {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func deleteVolume(_ target: Volume) throws(RuntimeError) {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func listImages() throws(RuntimeError) -> ImageListSnapshot {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func deleteImage(reference: ImageRef) throws(RuntimeError) {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    // MARK: - Day 16

    func create(_ spec: ContainerCreationSpec) throws(RuntimeError) -> ContainerID {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func cloneTemplate(for source: ContainerID) throws(RuntimeError) -> ContainerCloneTemplate {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func create(
        clonedFrom source: ContainerID,
        name: ContainerName,
        envOverride: [EnvironmentVariable]?
    ) throws(RuntimeError) -> ContainerID {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func pullImage(_ reference: ImageRef) throws(RuntimeError) -> AsyncThrowingStream<PullProgress, any Error> {
        throw .operationFailed(reason: "unimplemented in test double")
    }

    func delete(id: ContainerID) throws(RuntimeError) {
        throw .operationFailed(reason: "unimplemented in test double")
    }
}

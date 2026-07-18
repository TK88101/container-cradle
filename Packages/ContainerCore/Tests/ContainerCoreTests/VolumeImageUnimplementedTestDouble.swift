import ContainerCore

/// 测试替身的 M5 方法默认 stub（simplify/reuse panel 双双点名的 85 行重复的收敛点）。
///
/// **只对显式 opt-in 这个 marker 的替身生效**：`LiveContainerRuntimeClient` /
/// `FakeContainerRuntimeClient` 不声明它，漏实现照样编译红——
/// 「不给 protocol 默认实现，Live 漏实现必须编译红」的不变式**不受影响**，
/// 这正是当初拒绝在 `ContainerRuntimeClient` 上直接放默认实现的全部理由。
///
/// 将来协议再长方法，只改这一个文件，不再往 5 个替身里各贴一遍。
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
}

import ContainerCore

/// 本 App 构建时 pin 的 apple/container 版本（Day 22 T10）。
///
/// 用途只有一个：已装运行时 ≠ 这个版本时，更新区给一行**非阻断**提示「本 App 基于 X 构建并测试」（A9 / PLAN 依赖策略第 4 道闸）。
/// 与 `Package.swift` 的 `exact:` 和 `Package.resolved` 的一致性由 `UpstreamPinTests` 守——升级上游时改了那边忘了这里，测试会红。
///
/// **不 import 上游**，不进边界白名单。
public enum UpstreamPin {
    public static let version = RuntimeVersion(major: 1, minor: 4, patch: 1)
}

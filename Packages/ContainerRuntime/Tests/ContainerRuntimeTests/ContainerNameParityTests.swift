import ContainerCore
import ContainerResource
import Testing

/// `ContainerName`（ContainerCore，零上游）自称「逐字镜像上游容器名规则，不严不松」。
///
/// ContainerCore 里 import 不到上游（D1），那边的测试只能断言字面规则——上游改了规则它照绿。
/// 1.1.0 → 1.4.1 就发生过：上游加了 `count <= 63`，我们的正则版照单全收 64+ 字符名，
/// 用户过了 UI 校验、到 create 才被拒（CLAUDE.md「已经踩过的坑」）。
/// 这里在**能同时看见两边**的 target 里对照判定结果：上游再改规则，这组样本上就红。
///
/// 有限样本集守不住样本外的新规则——它守的是「已知边界上两边一致」，不是完备性证明。
@Suite("ContainerName ⇔ 上游 ManagedContainer.nameValid 边界对照")
struct ContainerNameParityTests {

    static let samples: [String] = [
        "",                                              // 空
        "a",                                             // 1 字符（上游 `+` 要求 ≥2）
        "ab",                                            // 最短合法
        "A9",
        "web.app-01_x",                                  // 全部允许的标点
        "_abc", ".abc", "-abc",                          // 首字符非法
        "ab c", " abc", "abc ",                          // 空格（不 trim）
        "ab/cd", "ab:cd", "ab@cd", "ab$cd",              // 非法字符
        "é1",                                            // 非 ASCII
        String(repeating: "a", count: 63),               // 上限
        String(repeating: "a", count: 64),               // 上限 + 1
        String(repeating: "a", count: 63) + "/",         // 超长且非法
    ]

    @Test("每个样本：ContainerName 能否构造 == 上游 nameValid", arguments: samples)
    func agreesWithUpstream(raw: String) {
        let ours = (try? ContainerName(raw)) != nil
        #expect(ours == ManagedContainer.nameValid(raw), "分歧：\(raw.debugDescription)（长度 \(raw.count)）")
    }
}

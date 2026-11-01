import AppKit
import ApplicationServices

/// 长截图自动滚动的步进状态机（#112）：每次滚动后等画面开始移动并停稳再滚下一步，按实测位移校准滚动条增量。
/// 纯逻辑：输入每帧追加的正文像素与接缝失败，时间由调用方传入；输出下一步动作，不读写屏幕或其他应用。
struct AutoScrollPlan {
    /// 采集循环据此执行的动作。
    enum Action: Equatable {
        /// 继续采样，不滚动。
        case wait
        /// 按该增量继续滚动：滚动条途径为 0–1 范围内的比例，方向键途径为按键次数。
        case scroll(by: Double)
        /// 本步跨出可配准范围：退回本步之前的位置。
        case rewind
        /// 曾经滚动过且本步无移动：已到底部，自动暂停。
        case bottom
        /// 首步无移动：来源不响应当前滚动途径。
        case unsupported
    }

    /// 停稳判定：画面移动后连续静止的采样数（采样间隔 100ms，即 200ms）。
    static let settledFrames = 2
    /// 单步最长等待；画面仍在移动也开始下一步。
    static let maximumWait: Duration = .milliseconds(1000)
    /// 滚动后无移动的到底判定时长。
    static let bottomWait: Duration = .milliseconds(1500)
    /// 滚动条途径的首步增量；之后按实测位移校准。
    static let initialStep = 0.01
    /// 方向键途径的首步按键次数；之后按实测位移校准。
    static let initialKeyPresses = 2.0

    /// 单步目标位移（像素）：滚动条途径为选区高度的 50%，方向键途径为 25%。
    private(set) var target: Int
    /// 校准时单步最多放大的倍数；方向键途径在中途采样时容易少计位移，放大更保守。
    private var growth = 4.0
    /// 接缝失败时目标位移是否一并减半；方向键途径用它避免校准后再次跨出可配准范围。
    private var shrinksTarget = false
    /// 下一步的滚动条增量。
    private(set) var step: Double
    /// 最近一次滚动或退回的时刻；到底或不支持后为 nil，直到再次 start。
    private var stepped: ContinuousClock.Instant?
    /// 本步以来累计追加的正文像素与连续静止帧数。
    private var moved = 0
    private var still = 0
    /// 正在等待退回后的画面停稳。
    private var rewinding = false
    /// 本次会话是否有任何一步产生过移动；区分到底与不支持。
    private var everMoved = false

    /// height为选区像素高度，单步目标取其一半；step 为首步增量，缺省为滚动条途径的增量。
    init(height: Int, step: Double = initialStep) {
        target = max(1, height / 2)
        self.step = step
    }

    /// height为选区像素高度；返回方向键途径的步进计划：单步目标为选区高度的 25%。
    static func keys(height: Int) -> AutoScrollPlan {
        var plan = AutoScrollPlan(height: height, step: initialKeyPresses)
        plan.target = max(1, height / 4)
        plan.growth = 1.5
        plan.shrinksTarget = true
        return plan
    }

    /// now为开始时刻；开始（或暂停后恢复）一轮自动滚动，返回第一步滚动。
    mutating func start(now: ContinuousClock.Instant) -> Action {
        rewinding = false
        begin(now)
        return .scroll(by: step)
    }

    /// shift为本帧追加的正文像素（静止为 0），now为采样时刻；返回下一步动作。
    mutating func frame(shift: Int, now: ContinuousClock.Instant) -> Action {
        guard let stepped else { return .wait }
        if shift > 0 {
            moved += shift
            still = 0
        } else {
            still += 1
        }
        if rewinding {
            // 退回后画面回到参照帧，停稳即按减半的步长重试。
            guard still >= Self.settledFrames else { return .wait }
            rewinding = false
            begin(now)
            return .scroll(by: step)
        }
        if moved > 0, still >= Self.settledFrames || now - stepped >= Self.maximumWait {
            everMoved = true
            // 按本步「增量/位移」比例换算到目标位移；放大有上限，避免一次跨出可配准范围。
            step = min(step * growth, step * Double(target) / Double(moved))
            begin(now)
            return .scroll(by: step)
        }
        guard moved == 0, now - stepped >= Self.bottomWait else { return .wait }
        self.stepped = nil
        return everMoved ? .bottom : .unsupported
    }

    /// now为接缝失败时刻；步长减半并返回退回，画面停稳后再重试。
    mutating func mismatch(now: ContinuousClock.Instant) -> Action {
        step /= 2
        if shrinksTarget { target = max(1, target / 2) }
        rewinding = true
        begin(now)
        return .rewind
    }

    /// now为本步开始时刻；清零本步的移动与静止计数，无返回值。
    private mutating func begin(_ now: ContinuousClock.Instant) {
        stepped = now
        moved = 0
        still = 0
    }
}

/// 自动滚动的方向键途径（#112）：Chromium 等不暴露可写滚动条的来源，把方向键直接投给来源进程。
/// 不产生鼠标事件，指针不动，用户可随意移动鼠标；调用方须已确认辅助功能权限。
/// 已知限制：按键进入来源当前焦点，焦点在输入框时画面不滚动，首步不动后改为手动；
/// 需要支持这类页面时重新评估滚动途径。
struct AutoScrollKeys {
    /// 向下、向上方向键的虚拟键码。
    private static let downKey: CGKeyCode = 125
    private static let upKey: CGKeyCode = 126
    /// 单步最多按键次数，避免校准异常时一次跨出可配准范围。
    private static let maximumPresses = 40

    /// 来源进程。
    let pid: pid_t
    /// 最近一步的按键次数，供接缝失败时退回。
    private var last = 0

    /// pid为选区下来源窗口的进程。
    init(pid: pid_t) { self.pid = pid }

    /// step 为校准后的按键次数；发送向下方向键，返回事件是否已发送。
    mutating func scroll(by step: Double) -> Bool {
        let presses = Self.presses(step)
        guard press(Self.downKey, count: presses) else { return false }
        last = presses
        return true
    }

    /// 无参数；按相同次数发送向上方向键退回最近一步，返回事件是否已发送。
    func rewind() -> Bool { press(Self.upKey, count: last) }

    /// step 为校准后的增量；返回按键次数：取整，限制在 1 到 maximumPresses。
    static func presses(_ step: Double) -> Int { min(maximumPresses, max(1, Int(step.rounded()))) }

    /// key 为虚拟键码，count 为次数；向来源进程发送按下与抬起，返回事件是否都已创建并发送。
    private func press(_ key: CGKeyCode, count: Int) -> Bool {
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return true
    }
}

/// 自动滚动目标（#112）：选区中心处来源窗口的纵向滚动条。只经辅助功能接口读写滚动条值，
/// 不移动指针；调用方须已确认辅助功能权限。
final class AutoScrollTarget {
    private let bar: AXUIElement

    /// point为 CG 全局坐标（左上原点）；返回该点最上层、非本应用普通窗口的进程，找不到时返回 nil。
    static func sourceProcess(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        // 窗口列表按前后顺序排列；第 0 层是普通应用窗口，采集遮罩等本应用窗口不参与。
        let owner = windows.first { info in
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? pid_t != own,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
        return owner?[kCGWindowOwnerPID as String] as? pid_t
    }

    /// point为 CG 全局坐标（左上原点）；返回该点来源窗口内可设置值的纵向滚动条，找不到时返回 nil。
    init?(point: CGPoint) {
        guard let pid = Self.sourceProcess(at: point) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        // 从命中元素向上找最近的滚动区；网页与列表都嵌在滚动区内，层级不超过 30。
        for _ in 0..<30 {
            if Self.attribute(current, kAXRoleAttribute) as? String == kAXScrollAreaRole as String,
               let found = Self.attribute(current, kAXVerticalScrollBarAttribute) {
                let bar = found as! AXUIElement
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
                      settable.boolValue else { return nil }
                self.bar = bar
                return
            }
            guard let parent = Self.attribute(current, kAXParentAttribute) else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// 无参数；返回当前滚动条值（0 顶部、1 底部），读取失败返回 nil。
    var value: Double? { (Self.attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue }

    /// value为目标值，截到 0–1；写入滚动条，返回是否成功。
    func set(_ value: Double) -> Bool {
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: min(1, max(0, value)))) == .success
    }

    /// element为辅助功能元素，name为属性名；返回属性值，读取失败返回 nil。
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

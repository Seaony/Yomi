import Testing
@testable import CodeEdge

struct AppDelegateTests {
    // 测试宿主就是 Yomi.app，必须识别出测试环境，才不会建侧边栏、用真实凭据刷新或检查更新。
    @Test
    func testHostIsDetected() {
        #expect(AppDelegate.isRunningTests)
    }
}

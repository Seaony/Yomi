import Foundation

// 测试仍注入 UserDefaults，但所有值只留在这个实例里，不交给偏好守护进程迟写。
nonisolated final class TestUserDefaults: UserDefaults, @unchecked Sendable {
    let suiteName: String
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    override init?(suiteName: String?) {
        guard let suiteName, TestUserDefaultsCleanup.accepts(suiteName) else { return nil }
        self.suiteName = suiteName
        super.init(suiteName: suiteName)
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] ?? registered[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        willChangeValue(forKey: defaultName)
        lock.withLock { values[defaultName] = value }
        didChangeValue(forKey: defaultName)
        changed()
    }

    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: URL?, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }

    override func string(forKey defaultName: String) -> String? {
        let value = object(forKey: defaultName)
        return value as? String ?? (value as? NSNumber)?.stringValue
    }

    override func bool(forKey defaultName: String) -> Bool {
        let value = object(forKey: defaultName)
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        let value = object(forKey: defaultName)
        return (value as? NSNumber)?.intValue ?? (value as? NSString)?.integerValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        let value = object(forKey: defaultName)
        return (value as? NSNumber)?.doubleValue ?? (value as? NSString)?.doubleValue ?? 0
    }

    override func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func url(forKey defaultName: String) -> URL? { object(forKey: defaultName) as? URL }
    override func value(forKey key: String) -> Any? { object(forKey: key) }
    override func setValue(_ value: Any?, forKey key: String) { set(value, forKey: key) }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock { registered.merge(registrationDictionary) { _, new in new } }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { _, new in new } }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        guard domainName == suiteName else { return nil }
        return lock.withLock { values }
    }

    override func removePersistentDomain(forName domainName: String) {
        guard domainName == suiteName else { return }
        lock.withLock { values.removeAll() }
        changed()
    }

    override func synchronize() -> Bool { true }

    private func changed() {
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
}

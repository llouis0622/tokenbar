import CSensors
import Darwin
import Foundation
import IOKit

public struct SystemSample: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var diskFree: Int64?
    public var diskTotal: Int64?
    public var upload: Double
    public var download: Double
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?

    public var memoryPercent: Double? {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : nil
    }

    public var diskPercent: Double? {
        guard let free = diskFree, let total = diskTotal, total > 0 else { return nil }
        return (1 - Double(free) / Double(total)) * 100
    }
}

public actor SystemMonitor {
    private struct CPUTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private struct NetCounters {
        var received: UInt32
        var sent: UInt32
    }

    private var lastCPU: CPUTicks?
    private var lastNet: [String: NetCounters] = [:]
    private var lastNetTime: Date?

    public init() {}

    public func sample(includeTemperatures: Bool, now: Date = Date()) -> SystemSample {
        let memory = Self.memory()
        let disk = Self.disk()
        let network = networkRates(now: now)
        var result = SystemSample(
            cpu: cpuUsage(),
            gpu: Self.gpuUsage(),
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            diskFree: disk.free,
            diskTotal: disk.total,
            upload: network.upload,
            download: network.download,
            cpuTemperature: nil,
            gpuTemperature: nil
        )
        if includeTemperatures {
            var cpu = -1.0
            var gpu = -1.0
            tb_read_temperatures(&cpu, &gpu)
            result.cpuTemperature = cpu > 0 ? cpu : nil
            result.gpuTemperature = gpu > 0 ? gpu : nil
        }
        return result
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let current = CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { lastCPU = current }
        guard let before = lastCPU else { return nil }
        let busy = UInt64(current.user &- before.user) + UInt64(current.system &- before.system) + UInt64(current.nice &- before.nice)
        let total = busy + UInt64(current.idle &- before.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    private static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(max(sysconf(_SC_PAGESIZE), 0))
        let held = UInt64(stats.active_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let reclaimable = UInt64(stats.purgeable_count) + UInt64(stats.external_page_count)
        let pages = held > reclaimable ? held - reclaimable : 0
        return (min(pages * page, total), total)
    }

    private static func disk() -> (free: Int64?, total: Int64?) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return (nil, nil) }
        return (values.volumeAvailableCapacityForImportantUsage, values.volumeTotalCapacity.map { Int64($0) })
    }

    private func networkRates(now: Date) -> (upload: Double, download: Double) {
        let current = Self.networkCounters()
        defer {
            lastNet = current
            lastNetTime = now
        }
        guard let before = lastNetTime else { return (0, 0) }
        let elapsed = now.timeIntervalSince(before)
        guard elapsed > 0 else { return (0, 0) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, counters) in current {
            guard let previous = lastNet[name] else { continue }
            received += UInt64(counters.received &- previous.received)
            sent += UInt64(counters.sent &- previous.sent)
        }
        return (Double(sent) / elapsed, Double(received) / elapsed)
    }

    private static func networkCounters() -> [String: NetCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: NetCounters] = [:]
        var cursor = head
        while let item = cursor {
            let entry = item.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let raw = entry.ifa_data
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = raw.assumingMemoryBound(to: if_data.self).pointee
            result[name] = NetCounters(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return result
    }

    private static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            guard let statistics = property?.takeRetainedValue() as? [String: Any] else { continue }
            let value = (statistics["Device Utilization %"] as? NSNumber) ?? (statistics["GPU Activity(%)"] as? NSNumber)
            if let value {
                best = max(best ?? 0, value.doubleValue)
            }
        }
        return best
    }
}

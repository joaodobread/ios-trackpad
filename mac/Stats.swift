// Amostragem de consumo do Mac: CPU, GPU, memória, rede, disco, bateria e processos.
// Tudo com APIs públicas (mach, IOKit, libproc), sem precisar de root.

import AppKit
import IOKit
import IOKit.ps

final class StatsSampler {
    private var prevTicks: (busy: Double, total: Double)?
    private var prevNet = [String: (i: UInt32, o: UInt32)]()
    private var prevNetTime: Double?
    private var prevProc = [pid_t: UInt64]()
    private var prevProcTime: Double?
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// "T cpu gpu memUsado memTotal redeEntrada redeSaída discoUsado discoTotal bateria carregando núcleos"
    /// (frações 0…1, bytes, bytes/s; -1 = indisponível)
    func line() -> String {
        let (inRate, outRate) = network()
        let (diskUsed, diskTotal) = disk()
        let (batt, charging) = battery()
        return String(format: "T %.3f %.3f %.0f %.0f %.0f %.0f %.0f %.0f %.3f %d %d",
                      cpu(), gpu() ?? -1, memoryUsed(), Double(ProcessInfo.processInfo.physicalMemory),
                      inRate, outRate, diskUsed, diskTotal, batt ?? -1, charging ? 1 : 0, ProcessInfo.processInfo.activeProcessorCount)
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let busy = Double(t.0) + Double(t.1) + Double(t.3) // user + system + nice
        let total = busy + Double(t.2)
        defer { prevTicks = (busy, total) }
        guard let p = prevTicks, total > p.total else { return 0 }
        return (busy - p.busy) / (total - p.total)
    }

    private func memoryUsed() -> Double {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        // como o "Memória usada" do Monitor de Atividade: app + wired + comprimida
        let pages = Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
        return pages * Double(vm_kernel_page_size)
    }

    private func gpu() -> Double? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let u = stats["Device Utilization %"] as? Int else { continue }
            best = max(best ?? 0, Double(u) / 100)
        }
        return best
    }

    private func network() -> (Double, Double) {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifa) }
        var cur = [String: (i: UInt32, o: UInt32)]()
        var p = ifa
        while let i = p {
            p = i.pointee.ifa_next
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), let data = i.pointee.ifa_data else { continue }
            let name = String(cString: i.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        let t = now
        defer { prevNet = cur; prevNetTime = t }
        guard let pt = prevNetTime, t > pt else { return (0, 0) }
        var di = 0.0, dout = 0.0
        for (name, v) in cur {
            guard let old = prevNet[name] else { continue }
            di += Double(v.i &- old.i) // contadores de 32 bits: subtração com estouro trata a volta
            dout += Double(v.o &- old.o)
        }
        return (di / (t - pt), dout / (t - pt))
    }

    private func disk() -> (Double, Double) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Double(v?.volumeTotalCapacity ?? 0)
        let free = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)
        return (max(total - free, 0), total)
    }

    private func battery() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return (Double(cur) / Double(max), charging)
        }
        return (nil, false)
    }

    /// "P nome␟cpu␟memória\t…" — top processos por CPU (cpu em fração de um núcleo, como o Monitor de Atividade)
    func processes(limit: Int = 8) -> String {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return "P " }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let t = now
        let dt = prevProcTime.map { t - $0 } ?? 0
        var cur = [pid_t: UInt64]()
        var rows = [(name: String, cpu: Double, mem: Double)]()
        for pid in pids.prefix(got) where pid > 0 {
            var ri = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = ri.ri_user_time + ri.ri_system_time // em ticks do mach no Apple Silicon
            cur[pid] = cpuTime
            guard dt > 0, let old = prevProc[pid], cpuTime >= old else { continue }
            let cpu = Double(cpuTime - old) * timebase / 1e9 / dt
            rows.append((name(pid), cpu, Double(ri.ri_phys_footprint)))
        }
        prevProc = cur
        prevProcTime = t
        let top = rows.sorted { $0.cpu > $1.cpu }.prefix(limit)
        return "P " + top.map { "\(clean($0.name))\u{1f}\(String(format: "%.3f", $0.cpu))\u{1f}\(String(format: "%.0f", $0.mem))" }.joined(separator: "\t")
    }

    private func name(_ pid: pid_t) -> String {
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }
}

/// Remove separadores do protocolo de nomes vindos do sistema.
func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{1f}", with: " ")
}

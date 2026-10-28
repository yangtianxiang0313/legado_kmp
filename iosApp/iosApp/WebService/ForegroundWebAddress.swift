import Foundation
import Darwin

enum ForegroundWebAddress {
    static func localIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET),
                item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                == 0
            {
                let value = String(cString: buffer)
                if value.hasPrefix("192.168.") || value.hasPrefix("10.") || value.hasPrefix("172.") { return value }
            }
        }
        return nil
    }
}

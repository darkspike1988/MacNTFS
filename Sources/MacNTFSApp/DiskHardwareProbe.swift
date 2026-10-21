import Foundation
import IOKit

public struct DiskHardwareInfo: Sendable {
    public var model: String
    public var vendor: String
    public var serialNumber: String
    public var busProtocol: String
    public var mediumType: String
    public var isSSD: Bool

    public static let empty = DiskHardwareInfo(
        model: "Allgemeines Speichermedium",
        vendor: "",
        serialNumber: "N/A",
        busProtocol: "Lokal",
        mediumType: "SSD",
        isSSD: true
    )
}

public enum DiskHardwareProbe {
    /// Queries the Apple IORegistry / IOKit hardware hierarchy for the specified BSD device name.
    public static func query(bsdPath: String) -> DiskHardwareInfo {
        let cleanBsd = bsdPath
            .replacingOccurrences(of: "/dev/r", with: "")
            .replacingOccurrences(of: "/dev/", with: "")

        let matchingDict = IOBSDNameMatching(kIOMainPortDefault, 0, cleanBsd)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        guard service != 0 else {
            return .empty
        }
        defer { IOObjectRelease(service) }

        var model = ""
        var vendor = ""
        var serial = ""
        var bus = ""
        var mediumType = ""
        var isSSD = false

        var parent: io_registry_entry_t = 0
        var current: io_registry_entry_t = service
        IOObjectRetain(current)

        while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
            IOObjectRelease(current)
            current = parent

            // 1. Device Characteristics dictionary (found on NVMe, SSD, and modern block drivers)
            if let dict = IORegistryEntryCreateCFProperty(current, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                if model.isEmpty, let pName = dict["Product Name"] as? String {
                    model = pName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if vendor.isEmpty, let vName = dict["Vendor Name"] as? String {
                    vendor = vName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if serial.isEmpty, let sn = dict["Serial Number"] as? String {
                    serial = sn.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let mType = dict["Medium Type"] as? String {
                    mediumType = mType.trimmingCharacters(in: .whitespacesAndNewlines)
                    if mediumType.lowercased().contains("solid") { isSSD = true }
                }
            }

            // 2. Direct Model / Product properties
            if model.isEmpty {
                if let pName = IORegistryEntryCreateCFProperty(current, "Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    model = pName.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let pName = IORegistryEntryCreateCFProperty(current, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    model = pName.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let mName = IORegistryEntryCreateCFProperty(current, "MediaName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, !mName.isEmpty && mName != "AppleAPFSMedia" {
                    model = mName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // 3. Direct Vendor properties
            if vendor.isEmpty {
                if let vName = IORegistryEntryCreateCFProperty(current, "Vendor Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    vendor = vName.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let vName = IORegistryEntryCreateCFProperty(current, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    vendor = vName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // 4. Direct Serial Number properties
            if serial.isEmpty {
                if let sn = IORegistryEntryCreateCFProperty(current, "Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    serial = sn.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let sn = IORegistryEntryCreateCFProperty(current, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    serial = sn.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let sn = IORegistryEntryCreateCFProperty(current, "kUSBSerialNumberString" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    serial = sn.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // 5. Bus / Protocol characteristics
            if bus.isEmpty {
                if let protoDict = IORegistryEntryCreateCFProperty(current, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                   let phys = protoDict["Physical Interconnect"] as? String {
                    bus = phys.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        IOObjectRelease(current)

        // Post-processing cleanup
        if model.isEmpty {
            if !vendor.isEmpty {
                model = "\(vendor) Laufwerk"
            } else {
                model = cleanBsd.starts(with: "disk0") ? "Apple Integrierte SSD" : "Externes Laufwerk (\(cleanBsd))"
            }
        }

        if bus.isEmpty {
            bus = cleanBsd.starts(with: "disk0") ? "Apple Fabric / NVMe" : "USB / Extern"
        }

        if serial.isEmpty {
            serial = "N/A"
        }

        return DiskHardwareInfo(
            model: model,
            vendor: vendor,
            serialNumber: serial,
            busProtocol: bus,
            mediumType: mediumType.isEmpty ? (isSSD ? "Solid State (SSD)" : "Festplatte") : mediumType,
            isSSD: isSSD
        )
    }
}

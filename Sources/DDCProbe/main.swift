import Foundation
import AppleSiliconDDC
import AppleSiliconDDCObjC
import BridgeCore

func device(_ service: AppleSiliconDDC.IOregService) -> DDCDevice {
    DDCDevice(manufacturer: service.manufacturerID, name: service.productName,
              serial: service.alphanumericSerialNumber, numericSerial: service.serialNumber,
              edid: service.edidUUID, location: service.ioDisplayLocation,
              upstream: service.transportUpstream, downstream: service.transportDownstream,
              serviceAvailable: service.service != nil)
}

// Read-only helper. A GetVCP request uses an I2C write, but NEVER a SetVCP opcode.
// Each invocation is isolated so the parent can enforce a deadline and rediscover services.
func read(_ entry: AppleSiliconDDC.IOregService) -> VCPReading {
    guard let service = entry.service else { return VCPReading(device: device(entry), raw: [], transportOK: false) }
    var request: [UInt8] = [0x82, 0x01, 0x60, 0x00]
    request[3] = request.prefix(3).reduce(UInt8(0x6e), ^)
    var last = VCPReading(device: device(entry), raw: [], transportOK: false)
    for _ in 0..<3 {
        usleep(10000)
        let written = IOAVServiceWriteI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == 0
        usleep(80000)
        var raw = [UInt8](repeating: 0, count: 11)
        let readOK = IOAVServiceReadI2C(service, 0x37, 0x51, &raw, UInt32(raw.count)) == 0
        last = VCPReading(device: device(entry), raw: raw, transportOK: written && readOK)
        if last.valid { return last }
        usleep(50000)
    }
    return last
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let entries = AppleSiliconDDC.getIoregServicesForMatching().filter { !$0.productName.isEmpty }
    if args == ["detect"] {
        print(try JSON.string(entries.map(device)))
    } else {
        guard args.count == 5, ["getvcp", "getvcp-zowie"].contains(args[0]), args[1] == "0x60", args[2] == "--serial" else {
            throw BridgeError("Usage: inputbridge-ddc detect | getvcp|getvcp-zowie 0x60 --serial SERIAL EDID")
        }
        // A separate read-only probe never changes the Dell selector or display mutation guard.
        let manufacturer = args[0] == "getvcp-zowie" ? "BNQ" : "DEL"
        let name = args[0] == "getvcp-zowie" ? "ZOWIE XL LCD" : "DELL S2725QC"
        let matches = entries.filter { $0.manufacturerID == manufacturer && $0.productName == name && $0.alphanumericSerialNumber == args[3] && $0.edidUUID == args[4] }
        guard matches.count == 1 else { throw BridgeError("\(name) DDC identity absent or ambiguous; refusing fallback") }
        print(try JSON.string(read(matches[0])))
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

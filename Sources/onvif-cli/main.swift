import Foundation
import ONVIFCore

func printUsage() {
    print("""
    onvif-cli — діагностика ONVIF-пристроїв

      onvif-cli discover [секунд]                 пошук пристроїв у локальній мережі
      onvif-cli info <адреса> [логін] [пароль]    повний звіт по пристрою

    <адреса>: 192.168.1.10, 192.168.1.10:8080 або http://host/onvif/device_service
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "discover":
    let timeout = arguments.count > 1 ? (Double(arguments[1]) ?? 4) : 4
    let devices = await WSDiscovery.probe(timeout: timeout)
    print("Знайдено: \(devices.count)")
    for d in devices {
        print("")
        print("\(d.name ?? "(без назви)") — \(d.sourceAddress)")
        print("  обладнання: \(d.hardware ?? "—")")
        print("  профілі:    \(d.profiles.isEmpty ? "—" : d.profiles.joined(separator: ", "))")
        print("  endpoint:   \(d.endpointReference)")
        for x in d.xaddrs { print("  xaddr:      \(x)") }
    }

case "info":
    guard arguments.count >= 2, let url = DeviceAddress.url(from: arguments[1]) else {
        printUsage()
        exit(1)
    }
    var credentials: Credentials?
    if arguments.count >= 3 {
        credentials = Credentials(username: arguments[2], password: arguments.count >= 4 ? arguments[3] : "")
    }
    let report = await DeviceReporter.build(url: url, credentials: credentials)
    print(report.text)
    exit(report.authFailed ? 2 : 0)

default:
    printUsage()
    exit(1)
}

import Foundation

/// Collects everything we can read from a device into a `DeviceReport`.
/// Each section is fetched independently: a failure becomes an error row, not a failed report.
public enum DeviceReporter {
    struct StreamInfo {
        var title: String
        var summary: String
        var uri: String?
    }

    // MARK: - Discovery-only view (before login)

    public static func discoveryReport(_ d: DiscoveredDevice) -> [ReportNode] {
        let disc = ReportNode("Виявлення (WS-Discovery)")
        disc.add("Відповідь з адреси", d.sourceAddress)
        disc.add("Endpoint", d.endpointReference)
        disc.addIf("Назва", d.name)
        disc.addIf("Обладнання", d.hardware)
        if !d.locations.isEmpty { disc.add("Розташування", d.locations.joined(separator: ", ")) }
        disc.add("Профілі ONVIF (за scopes)", d.profiles.isEmpty ? nil : d.profiles.joined(separator: ", "))
        let xaddrs = ReportNode("XAddrs", d.serviceURL?.absoluteString ?? "")
        for x in d.xaddrs { xaddrs.append(ReportNode(x)) }
        disc.append(xaddrs)
        disc.add("Types", d.types.joined(separator: " "))
        disc.addIf("MetadataVersion", d.metadataVersion)

        let scopes = ReportNode("Scopes", "\(d.scopes.count)")
        for s in d.scopes { scopes.append(ReportNode(s.removingPercentEncoding ?? s)) }
        return [disc, scopes]
    }

    // MARK: - Full report

    public static func build(url: URL, credentials: Credentials?) async -> DeviceReport {
        let dev = ONVIFDevice(url: url, credentials: credentials)
        var sections: [ReportNode] = []

        let connection = ReportNode("Підключення")
        connection.add("Device service", url.absoluteString)
        connection.add("Користувач", (credentials?.isEmpty ?? true) ? "(без авторизації)" : credentials?.username)
        sections.append(connection)

        // Clock first: WS-Security digests are rejected when the clocks differ too much.
        sections.append(await timeSection(dev))

        // Device information doubles as the credentials check.
        let info = ReportNode("Пристрій")
        var summary: DeviceSummary?
        do {
            let r = try await dev.device("GetDeviceInformation", "<tds:GetDeviceInformation/>")
            let s = DeviceSummary(
                manufacturer: r.string("Manufacturer") ?? "",
                model: r.string("Model") ?? "",
                firmware: r.string("FirmwareVersion") ?? "",
                serial: r.string("SerialNumber") ?? "",
                hardwareId: r.string("HardwareId") ?? ""
            )
            summary = s
            info.add("Виробник", s.manufacturer)
            info.add("Модель", s.model)
            info.add("Версія прошивки", s.firmware)
            info.add("Серійний номер", s.serial)
            info.add("Hardware ID", s.hardwareId)
        } catch let error as ONVIFError where error.isAuthError {
            info.addError(error)
            info.append(ReportNode("Підказка", "Перевірте логін і пароль ONVIF-користувача та час на камері", isError: true))
            sections.append(info)
            return DeviceReport(sections: sections, summary: nil, authFailed: true)
        } catch {
            info.addError(error)
        }
        sections.append(info)

        let (servicesNode, serviceVersions) = await servicesSection(dev)
        let (capsNode, supportedVersions) = await capabilitiesSection(dev)
        sections.append(servicesNode)
        sections.append(capsNode)

        let (scopesNode, scopes) = await scopesSection(dev)
        sections.append(scopesNode)
        sections.append(await networkSection(dev))

        var streams: [StreamInfo] = []
        if dev.has(ONVIFNamespace.media) {
            let (node, s) = await media1Section(dev)
            sections.append(node)
            streams += s
        }
        if dev.has(ONVIFNamespace.media2) {
            let (node, s) = await media2Section(dev)
            sections.append(node)
            streams += s
        }
        if !dev.has(ONVIFNamespace.media) && !dev.has(ONVIFNamespace.media2) {
            sections.append(ReportNode("Медіа", "сервіс Media не знайдено", isError: true))
        }
        var ptzSummary: String?
        if dev.has(ONVIFNamespace.ptz) {
            let (node, summaryText) = await ptzSection(dev)
            sections.append(node)
            ptzSummary = summaryText
        }

        // Overview goes right after "Connection".
        let overview = ReportNode("Огляд")
        if let s = summary {
            overview.add("Пристрій", [s.manufacturer, s.model].filter { !$0.isEmpty }.joined(separator: " "))
            overview.add("Прошивка", s.firmware)
        }
        overview.add("Версії ONVIF (SupportedVersions)",
                     supportedVersions.isEmpty ? nil : supportedVersions.joined(separator: ", "))
        if let deviceVersion = serviceVersions[ONVIFNamespace.device] {
            overview.add("Версія Device service", deviceVersion)
        }
        let profiles = ONVIFScopes.profiles(scopes)
        if profiles.isEmpty {
            // Not every device announces profiles in scopes: estimate from the services it exposes.
            var guessed: [String] = []
            if dev.has(ONVIFNamespace.media) { guessed.append("S") }
            if dev.has(ONVIFNamespace.media2) { guessed.append("T") }
            if dev.has(ONVIFNamespace.recording) && dev.has(ONVIFNamespace.search) && dev.has(ONVIFNamespace.replay) {
                guessed.append("G")
            }
            overview.add("Профілі ONVIF",
                         "не вказані в scopes" + (guessed.isEmpty ? "" : "; за сервісами ймовірно: " + guessed.joined(separator: ", ")))
        } else {
            overview.add("Профілі ONVIF (за scopes)", profiles.joined(separator: ", "))
        }
        let serviceNames = dev.serviceURLs.keys.map { ONVIFNamespace.friendlyName($0) }.sorted()
        overview.add("Сервіси", serviceNames.isEmpty ? nil : serviceNames.joined(separator: ", "))
        overview.add("PTZ", dev.has(ONVIFNamespace.ptz) ? (ptzSummary ?? "є") : "немає")
        let streamsNode = ReportNode("Потоки", "\(streams.count)")
        for s in streams {
            let n = ReportNode(s.title, s.summary)
            n.add("RTSP", s.uri)
            streamsNode.append(n)
        }
        overview.append(streamsNode)
        sections.insert(overview, at: 1)

        return DeviceReport(sections: sections, summary: summary, authFailed: false)
    }

    // MARK: - Sections

    private static func timeSection(_ dev: ONVIFDevice) async -> ReportNode {
        let node = ReportNode("Дата і час")
        let body = "<tds:GetSystemDateAndTime/>"
        var response: XNode?
        do {
            response = try await dev.device("GetSystemDateAndTime", body, authenticated: false)
        } catch {
            // Some devices require authentication even for this call.
            do {
                response = try await dev.device("GetSystemDateAndTime", body)
            } catch {
                node.addError(error)
            }
        }
        guard let sdt = response?.child("SystemDateAndTime") else { return node }

        node.add("Режим", sdt.string("DateTimeType"))
        node.add("Літній час", sdt.string("DaylightSavings"))
        node.add("Часовий пояс (TZ)", sdt.string("TimeZone", "TZ"))
        if let utcNode = sdt.child("UTCDateTime"), let utc = ONVIFDevice.date(from: utcNode) {
            let formatter = ISO8601DateFormatter()
            node.add("Час пристрою (UTC)", formatter.string(from: utc))
            let offset = utc.timeIntervalSinceNow
            dev.client.timeOffset = offset
            node.add("Різниця з цим комп'ютером", formatOffset(offset))
        }
        if let local = sdt.child("LocalDateTime") {
            let d = [local.string("Date", "Year"), local.string("Date", "Month"), local.string("Date", "Day")]
                .map { $0 ?? "?" }.joined(separator: "-")
            let t = [local.string("Time", "Hour"), local.string("Time", "Minute"), local.string("Time", "Second")]
                .map { $0 ?? "?" }.joined(separator: ":")
            node.add("Локальний час пристрою", "\(d) \(t)")
        }
        return node
    }

    static func formatOffset(_ offset: TimeInterval) -> String {
        let total = Int(abs(offset).rounded())
        if total < 5 { return "немає (\(total) с)" }
        let days = total / 86_400, hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60, seconds = total % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) д") }
        if hours > 0 { parts.append("\(hours) год") }
        if minutes > 0 { parts.append("\(minutes) хв") }
        if days == 0 && hours == 0 { parts.append("\(seconds) с") }
        let direction = offset < 0 ? "годинник пристрою відстає" : "годинник пристрою поспішає"
        return parts.joined(separator: " ") + " — " + direction
    }

    private static func version(_ node: XNode?) -> String? {
        guard let n = node, let major = n.string("Major") else { return nil }
        return "\(major).\(n.string("Minor") ?? "0")"
    }

    private static func servicesSection(_ dev: ONVIFDevice) async -> (ReportNode, [String: String]) {
        let node = ReportNode("Сервіси ONVIF (GetServices)")
        var versions: [String: String] = [:]
        do {
            let r = try await dev.device("GetServices",
                "<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>")
            for s in r.children(named: "Service") {
                let ns = s.string("Namespace") ?? "?"
                let xaddr = s.string("XAddr") ?? ""
                let ver = version(s.child("Version"))
                if let v = ver { versions[ns] = v }
                dev.registerService(ns, xaddr: xaddr)
                let row = ReportNode(ONVIFNamespace.friendlyName(ns),
                                     [ver.map { "v\($0)" }, xaddr].compactMap { $0 }.filter { !$0.isEmpty }
                                        .joined(separator: " — "))
                row.add("Namespace", ns)
                row.add("XAddr", xaddr)
                row.add("Версія", ver)
                if let caps = s.child("Capabilities") {
                    row.append(ReportNode.fromXML(caps.children.first ?? caps, title: "Можливості"))
                }
                node.append(row)
            }
            node.value = "\(node.children.count)"
        } catch {
            node.addError(error)
        }
        return (node, versions)
    }

    private static func capabilitiesSection(_ dev: ONVIFDevice) async -> (ReportNode, [String]) {
        let node = ReportNode("Можливості (GetCapabilities)")
        var supported: [String] = []
        do {
            let r = try await dev.device("GetCapabilities",
                "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>")
            guard let caps = r.child("Capabilities") else { return (node, supported) }
            for c in caps.children { node.append(ReportNode.fromXML(c)) }

            // Older devices have no GetServices: take service endpoints from here.
            let fallback: [(String, [String])] = [
                (ONVIFNamespace.media, ["Media", "XAddr"]),
                (ONVIFNamespace.ptz, ["PTZ", "XAddr"]),
                (ONVIFNamespace.imaging, ["Imaging", "XAddr"]),
                (ONVIFNamespace.events, ["Events", "XAddr"]),
                (ONVIFNamespace.analytics, ["Analytics", "XAddr"]),
                (ONVIFNamespace.deviceIO, ["Extension", "DeviceIO", "XAddr"]),
                (ONVIFNamespace.recording, ["Extension", "Recording", "XAddr"]),
                (ONVIFNamespace.search, ["Extension", "Search", "XAddr"]),
                (ONVIFNamespace.replay, ["Extension", "Replay", "XAddr"]),
            ]
            for (ns, path) in fallback {
                if let xaddr = caps.at(path)?.value, !xaddr.isEmpty {
                    dev.registerService(ns, xaddr: xaddr, overwrite: false)
                }
            }

            for v in caps.at("Device", "System")?.children(named: "SupportedVersions") ?? [] {
                if let s = version(v), !supported.contains(s) { supported.append(s) }
            }
            supported.sort { (Double($0) ?? 0) > (Double($1) ?? 0) }
        } catch {
            node.addError(error)
        }
        return (node, supported)
    }

    private static func scopesSection(_ dev: ONVIFDevice) async -> (ReportNode, [String]) {
        let node = ReportNode("Scopes")
        var scopes: [String] = []
        do {
            let r = try await dev.device("GetScopes", "<tds:GetScopes/>")
            for s in r.children(named: "Scopes") {
                guard let item = s.string("ScopeItem") else { continue }
                scopes.append(item)
                node.append(ReportNode(item.removingPercentEncoding ?? item, s.string("ScopeDef") ?? ""))
            }
            node.value = "\(scopes.count)"
        } catch {
            node.addError(error)
        }
        return (node, scopes)
    }

    private static func networkSection(_ dev: ONVIFDevice) async -> ReportNode {
        let node = ReportNode("Мережа")

        do {
            let r = try await dev.device("GetHostname", "<tds:GetHostname/>")
            let fromDHCP = r.string("HostnameInformation", "FromDHCP") == "true" ? " (DHCP)" : ""
            node.add("Ім'я хоста", (r.string("HostnameInformation", "Name") ?? "—") + fromDHCP)
        } catch {
            node.addError(error, title: "Ім'я хоста")
        }

        do {
            let r = try await dev.device("GetNetworkInterfaces", "<tds:GetNetworkInterfaces/>")
            for iface in r.children(named: "NetworkInterfaces") {
                let title = iface.string("Info", "Name") ?? iface.attr("token") ?? "Інтерфейс"
                let row = ReportNode("Інтерфейс \(title)", iface.string("Info", "HwAddress") ?? "")
                row.add("Token", iface.attr("token"))
                row.add("Увімкнено", iface.string("Enabled"))
                row.add("MAC", iface.string("Info", "HwAddress"))
                row.addIf("MTU", iface.string("Info", "MTU"))
                if let v4 = iface.at("IPv4", "Config") {
                    row.add("IPv4 DHCP", v4.string("DHCP"))
                    for kind in ["Manual", "FromDHCP", "LinkLocal"] {
                        for a in v4.children(named: kind) {
                            if let addr = a.string("Address") {
                                row.add("IPv4 (\(kind))", addr + (a.string("PrefixLength").map { "/\($0)" } ?? ""))
                            }
                        }
                    }
                }
                node.append(row)
            }
        } catch {
            node.addError(error, title: "Інтерфейси")
        }

        do {
            let r = try await dev.device("GetNetworkDefaultGateway", "<tds:GetNetworkDefaultGateway/>")
            let gw = r.child("NetworkGateway")?.children(named: "IPv4Address").map { $0.value } ?? []
            node.add("Шлюз", gw.isEmpty ? nil : gw.joined(separator: ", "))
        } catch {
            node.addError(error, title: "Шлюз")
        }

        do {
            let r = try await dev.device("GetDNS", "<tds:GetDNS/>")
            if let info = r.child("DNSInformation") {
                var servers: [String] = []
                for kind in ["DNSManual", "DNSFromDHCP"] {
                    for d in info.children(named: kind) {
                        if let a = d.string("IPv4Address") ?? d.string("IPv6Address") { servers.append(a) }
                    }
                }
                node.add("DNS", servers.isEmpty ? nil : servers.joined(separator: ", "))
            }
        } catch {
            node.addError(error, title: "DNS")
        }

        do {
            let r = try await dev.device("GetNetworkProtocols", "<tds:GetNetworkProtocols/>")
            let protocols = ReportNode("Протоколи")
            for p in r.children(named: "NetworkProtocols") {
                let ports = p.children(named: "Port").map { $0.value }.joined(separator: ", ")
                let enabled = p.string("Enabled") == "true" ? "увімкнено" : "вимкнено"
                protocols.append(ReportNode(p.string("Name") ?? "?", "порт \(ports.isEmpty ? "—" : ports), \(enabled)"))
            }
            node.append(protocols)
        } catch {
            node.addError(error, title: "Протоколи")
        }

        do {
            let r = try await dev.device("GetNTP", "<tds:GetNTP/>")
            if let ntp = r.child("NTPInformation") {
                var servers: [String] = []
                for kind in ["NTPManual", "NTPFromDHCP"] {
                    for n in ntp.children(named: kind) {
                        if let a = n.string("DNSname") ?? n.string("IPv4Address") ?? n.string("IPv6Address") {
                            servers.append(a)
                        }
                    }
                }
                node.add("NTP", servers.isEmpty ? nil : servers.joined(separator: ", "))
            }
        } catch {
            node.addError(error, title: "NTP")
        }

        return node
    }

    // MARK: - PTZ

    /// Token of the first media profile that has a PTZ configuration (presets are per profile).
    private static func ptzProfileToken(_ dev: ONVIFDevice) async -> String? {
        if dev.has(ONVIFNamespace.media),
           let r = try? await dev.service(ONVIFNamespace.media, "GetProfiles", "<trt:GetProfiles/>") {
            if let p = r.children(named: "Profiles").first(where: { $0.child("PTZConfiguration") != nil }) {
                return p.attr("token")
            }
        }
        if dev.has(ONVIFNamespace.media2),
           let r = try? await dev.service(ONVIFNamespace.media2, "GetProfiles",
                                          "<tr2:GetProfiles><tr2:Type>PTZ</tr2:Type></tr2:GetProfiles>") {
            if let p = r.children(named: "Profiles").first(where: { $0.at("Configurations", "PTZ") != nil }) {
                return p.attr("token")
            }
        }
        return nil
    }

    private static func spaceRange(_ space: XNode) -> String? {
        var parts: [String] = []
        for (axis, label) in [("XRange", "X"), ("YRange", "Y")] {
            if let r = space.child(axis) {
                parts.append("\(label): \(r.string("Min") ?? "?")…\(r.string("Max") ?? "?")")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func ptzSection(_ dev: ONVIFDevice) async -> (ReportNode, String?) {
        let ns = ONVIFNamespace.ptz
        let node = ReportNode("PTZ")
        var summary: String?

        do {
            let r = try await dev.service(ns, "GetNodes", "<tptz:GetNodes/>")
            let nodes = r.children(named: "PTZNode")
            for n in nodes {
                let row = ReportNode("Вузол \(n.string("Name") ?? n.attr("token") ?? "")")
                row.add("Token", n.attr("token"))
                let spaces = n.child("SupportedPTZSpaces")
                func has(_ name: String) -> Bool { spaces?.child(name) != nil }

                var panTilt: [String] = []
                if has("AbsolutePanTiltPositionSpace") { panTilt.append("абсолютний") }
                if has("RelativePanTiltTranslationSpace") { panTilt.append("відносний") }
                if has("ContinuousPanTiltVelocitySpace") { panTilt.append("безперервний") }
                var zoom: [String] = []
                if has("AbsoluteZoomPositionSpace") { zoom.append("абсолютний") }
                if has("RelativeZoomTranslationSpace") { zoom.append("відносний") }
                if has("ContinuousZoomVelocitySpace") { zoom.append("безперервний") }
                row.add("Поворот/нахил (Pan/Tilt)", panTilt.isEmpty ? "немає" : panTilt.joined(separator: ", "))
                row.add("Zoom", zoom.isEmpty ? "немає" : zoom.joined(separator: ", "))
                row.add("Максимум пресетів", n.string("MaximumNumberOfPresets"))
                row.add("Home-позиція", n.string("HomeSupported") == "true"
                        ? (n.attr("FixedHomePosition") == "true" ? "так (фіксована)" : "так")
                        : "ні")
                let aux = n.children(named: "AuxiliaryCommands").map { $0.value }
                row.addIf("Допоміжні команди", aux.joined(separator: ", "))
                if let tours = n.at("Extension", "SupportedPresetTour") {
                    row.addIf("Тури пресетів (максимум)", tours.string("MaximumNumberOfPresetTours"))
                }

                if let spaces = spaces {
                    let spacesNode = ReportNode("Простори координат")
                    for space in spaces.children where space.name != "Extension" {
                        spacesNode.append(ReportNode(space.name, spaceRange(space) ?? (space.string("URI") ?? "")))
                    }
                    row.append(spacesNode)
                }
                node.append(row)

                if summary == nil {
                    var parts: [String] = []
                    if !panTilt.isEmpty { parts.append("Pan/Tilt") }
                    if !zoom.isEmpty { parts.append("Zoom") }
                    if let max = n.string("MaximumNumberOfPresets") { parts.append("пресетів до \(max)") }
                    summary = parts.isEmpty ? "є" : parts.joined(separator: ", ")
                }
            }
            node.value = "вузлів: \(nodes.count)"
        } catch {
            node.addError(error, title: "Вузли (GetNodes)")
        }

        do {
            let r = try await dev.service(ns, "GetConfigurations", "<tptz:GetConfigurations/>")
            let configs = ReportNode("Конфігурації")
            for c in r.children(named: "PTZConfiguration") {
                configs.append(ReportNode.fromXML(c, title: c.string("Name") ?? c.attr("token") ?? "PTZConfiguration"))
            }
            node.append(configs)
        } catch {
            node.addError(error, title: "Конфігурації")
        }

        if let token = await ptzProfileToken(dev) {
            do {
                let r = try await dev.service(ns, "GetPresets",
                    "<tptz:GetPresets><tptz:ProfileToken>\(xmlEscape(token))</tptz:ProfileToken></tptz:GetPresets>")
                let presets = r.children(named: "Preset")
                let list = ReportNode("Пресети (профіль \(token))", "\(presets.count)")
                for p in presets {
                    var position = ""
                    if let pt = p.at("PTZPosition", "PanTilt") {
                        position = "x=\(pt.attr("x") ?? "?") y=\(pt.attr("y") ?? "?")"
                    }
                    if let z = p.at("PTZPosition", "Zoom") {
                        position += (position.isEmpty ? "" : " ") + "zoom=\(z.attr("x") ?? "?")"
                    }
                    let title = p.string("Name") ?? p.attr("token") ?? "?"
                    list.append(ReportNode(title, position.isEmpty ? "token \(p.attr("token") ?? "?")" : position))
                }
                node.append(list)
            } catch {
                node.addError(error, title: "Пресети")
            }
        }
        return (node, summary)
    }

    // MARK: - Media (ver10)

    private static func media1Section(_ dev: ONVIFDevice) async -> (ReportNode, [StreamInfo]) {
        let ns = ONVIFNamespace.media
        let node = ReportNode("Медіа-профілі (Media ver10)")
        var streams: [StreamInfo] = []
        let profiles: [XNode]
        do {
            profiles = try await dev.service(ns, "GetProfiles", "<trt:GetProfiles/>").children(named: "Profiles")
        } catch {
            node.addError(error)
            return (node, streams)
        }
        node.value = "\(profiles.count)"

        for p in profiles {
            let token = p.attr("token") ?? ""
            let row = ReportNode(p.string("Name") ?? token)
            row.add("Token", token)
            row.addIf("Fixed", p.attr("fixed"))

            if let vs = p.child("VideoSourceConfiguration") {
                let b = vs.child("Bounds")
                let bounds = b.map { "\($0.attr("width") ?? "?")x\($0.attr("height") ?? "?")" } ?? ""
                row.add("Відеоджерело", [vs.string("SourceToken") ?? "", bounds].filter { !$0.isEmpty }.joined(separator: ", "))
            }

            var summary = ""
            if let ve = p.child("VideoEncoderConfiguration") {
                let encoding = ve.string("Encoding") ?? "?"
                let resolution = "\(ve.string("Resolution", "Width") ?? "?")x\(ve.string("Resolution", "Height") ?? "?")"
                let fps = ve.string("RateControl", "FrameRateLimit")
                summary = "\(encoding) \(resolution)" + (fps.map { " @ \($0) fps" } ?? "")
                let enc = ReportNode("Відеоенкодер", summary)
                enc.add("Token", ve.attr("token"))
                enc.addIf("Назва", ve.string("Name"))
                enc.add("Кодек", encoding)
                enc.add("Роздільність", resolution)
                enc.add("Якість", ve.string("Quality"))
                enc.add("FPS (ліміт)", fps)
                enc.addIf("Інтервал кодування", ve.string("RateControl", "EncodingInterval"))
                enc.add("Бітрейт (кбіт/с)", ve.string("RateControl", "BitrateLimit"))
                enc.addIf("GOV (H.264)", ve.string("H264", "GovLength"))
                enc.addIf("Профіль H.264", ve.string("H264", "H264Profile"))
                enc.addIf("GOV (MPEG4)", ve.string("MPEG4", "GovLength"))
                enc.addIf("Session timeout", ve.string("SessionTimeout"))
                if let vt = ve.attr("token") {
                    do {
                        let r = try await dev.service(ns, "GetVideoEncoderConfigurationOptions",
                            "<trt:GetVideoEncoderConfigurationOptions><trt:ConfigurationToken>\(xmlEscape(vt))</trt:ConfigurationToken>"
                            + "<trt:ProfileToken>\(xmlEscape(token))</trt:ProfileToken></trt:GetVideoEncoderConfigurationOptions>")
                        if let options = r.child("Options") { enc.append(media1EncoderOptions(options)) }
                    } catch {
                        enc.addError(error, title: "Опції енкодера")
                    }
                }
                row.append(enc)
            }
            row.value = summary

            if let ae = p.child("AudioEncoderConfiguration") {
                let a = ReportNode("Аудіоенкодер", ae.string("Encoding") ?? "")
                a.addIf("Бітрейт", ae.string("Bitrate"))
                a.addIf("Частота дискретизації", ae.string("SampleRate"))
                row.append(a)
            }
            if let ptz = p.child("PTZConfiguration") { row.add("PTZ", "так (\(ptz.attr("token") ?? ""))") }
            if p.child("MetadataConfiguration") != nil { row.add("Метадані", "так") }
            if p.child("VideoAnalyticsConfiguration") != nil { row.add("Відеоаналітика", "так") }

            var uri: String?
            do {
                let r = try await dev.service(ns, "GetStreamUri",
                    "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>"
                    + "<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>"
                    + "<trt:ProfileToken>\(xmlEscape(token))</trt:ProfileToken></trt:GetStreamUri>")
                uri = r.string("MediaUri", "Uri")
                row.add("RTSP URI", uri)
            } catch {
                row.addError(error, title: "RTSP URI")
            }
            do {
                let r = try await dev.service(ns, "GetSnapshotUri",
                    "<trt:GetSnapshotUri><trt:ProfileToken>\(xmlEscape(token))</trt:ProfileToken></trt:GetSnapshotUri>")
                row.add("Snapshot URI", r.string("MediaUri", "Uri"))
            } catch {
                row.addError(error, title: "Snapshot URI")
            }

            node.append(row)
            streams.append(StreamInfo(title: "\(row.title) (Media)", summary: summary, uri: uri))
        }
        return (node, streams)
    }

    private static func range(_ node: XNode?) -> String? {
        guard let n = node else { return nil }
        return "\(n.string("Min") ?? "?")–\(n.string("Max") ?? "?")"
    }

    private static func media1EncoderOptions(_ options: XNode) -> ReportNode {
        let node = ReportNode("Доступні опції")
        node.addIf("Якість", range(options.child("QualityRange")))

        func codec(_ c: XNode, title: String) {
            let row = ReportNode(title)
            let resolutions = c.children(named: "ResolutionsAvailable").map {
                "\($0.string("Width") ?? "?")x\($0.string("Height") ?? "?")"
            }
            row.addIf("Роздільності", resolutions.joined(separator: ", "))
            row.addIf("FPS", range(c.child("FrameRateRange")))
            row.addIf("Інтервал кодування", range(c.child("EncodingIntervalRange")))
            row.addIf("GOV", range(c.child("GovLengthRange")))
            row.addIf("Бітрейт (кбіт/с)", range(c.child("BitrateRange")))
            let profiles = (c.children(named: "H264ProfilesSupported") + c.children(named: "Mpeg4ProfilesSupported"))
                .map { $0.value }
            row.addIf("Профілі", profiles.joined(separator: ", "))
            if !row.children.isEmpty { node.append(row) }
        }

        let codecs = ["JPEG", "MPEG4", "H264"]
        for c in options.children where codecs.contains(c.name) { codec(c, title: c.name) }
        if let ext = options.child("Extension") {
            for c in ext.children where codecs.contains(c.name) { codec(c, title: "\(c.name) (розширено)") }
        }
        return node
    }

    // MARK: - Media2 (ver20)

    private static func media2Section(_ dev: ONVIFDevice) async -> (ReportNode, [StreamInfo]) {
        let ns = ONVIFNamespace.media2
        let node = ReportNode("Медіа-профілі (Media2 ver20)")
        var streams: [StreamInfo] = []
        let profiles: [XNode]
        do {
            profiles = try await dev.service(ns, "GetProfiles",
                "<tr2:GetProfiles><tr2:Type>All</tr2:Type></tr2:GetProfiles>").children(named: "Profiles")
        } catch {
            node.addError(error)
            return (node, streams)
        }
        node.value = "\(profiles.count)"

        for p in profiles {
            let token = p.attr("token") ?? ""
            let row = ReportNode(p.string("Name") ?? token)
            row.add("Token", token)
            row.addIf("Fixed", p.attr("fixed"))
            let configs = p.child("Configurations")

            if let vs = configs?.child("VideoSource") {
                let b = vs.child("Bounds")
                let bounds = b.map { "\($0.attr("width") ?? "?")x\($0.attr("height") ?? "?")" } ?? ""
                row.add("Відеоджерело", [vs.string("SourceToken") ?? "", bounds].filter { !$0.isEmpty }.joined(separator: ", "))
            }

            var summary = ""
            if let ve = configs?.child("VideoEncoder") {
                let encoding = ve.string("Encoding") ?? "?"
                let resolution = "\(ve.string("Resolution", "Width") ?? "?")x\(ve.string("Resolution", "Height") ?? "?")"
                let fps = ve.string("RateControl", "FrameRateLimit")
                summary = "\(encoding) \(resolution)" + (fps.map { " @ \($0) fps" } ?? "")
                let enc = ReportNode("Відеоенкодер", summary)
                enc.add("Token", ve.attr("token"))
                enc.addIf("Назва", ve.string("Name"))
                enc.add("Кодек", encoding)
                enc.add("Роздільність", resolution)
                enc.addIf("Якість", ve.string("Quality"))
                enc.add("FPS (ліміт)", fps)
                enc.add("Бітрейт (кбіт/с)", ve.string("RateControl", "BitrateLimit"))
                enc.addIf("Постійний бітрейт", ve.child("RateControl")?.attr("ConstantBitRate"))
                enc.addIf("GOV", ve.attr("GovLength"))
                enc.addIf("Профіль", ve.attr("Profile"))
                if let vt = ve.attr("token") {
                    do {
                        let r = try await dev.service(ns, "GetVideoEncoderConfigurationOptions",
                            "<tr2:GetVideoEncoderConfigurationOptions><tr2:ConfigurationToken>\(xmlEscape(vt))</tr2:ConfigurationToken>"
                            + "<tr2:ProfileToken>\(xmlEscape(token))</tr2:ProfileToken></tr2:GetVideoEncoderConfigurationOptions>")
                        let opts = ReportNode("Доступні опції")
                        for o in r.children(named: "Options") {
                            let orow = ReportNode(o.string("Encoding") ?? "?")
                            let resolutions = o.children(named: "ResolutionsAvailable").map {
                                "\($0.string("Width") ?? "?")x\($0.string("Height") ?? "?")"
                            }
                            orow.addIf("Роздільності", resolutions.joined(separator: ", "))
                            orow.addIf("FPS", o.attr("FrameRatesSupported"))
                            orow.addIf("GOV", o.attr("GovLengthRange"))
                            orow.addIf("Профілі", o.attr("ProfilesSupported"))
                            orow.addIf("Бітрейт (кбіт/с)", range(o.child("BitrateRange")))
                            orow.addIf("Якість", range(o.child("QualityRange")))
                            orow.addIf("Постійний бітрейт", o.attr("ConstantBitRateSupported"))
                            opts.append(orow)
                        }
                        enc.append(opts)
                    } catch {
                        enc.addError(error, title: "Опції енкодера")
                    }
                }
                row.append(enc)
            }
            row.value = summary

            if let ae = configs?.child("AudioEncoder") {
                let a = ReportNode("Аудіоенкодер", ae.string("Encoding") ?? "")
                a.addIf("Бітрейт", ae.string("Bitrate"))
                a.addIf("Частота дискретизації", ae.string("SampleRate"))
                row.append(a)
            }
            if configs?.child("PTZ") != nil { row.add("PTZ", "так") }
            if configs?.child("Metadata") != nil { row.add("Метадані", "так") }
            if configs?.child("Analytics") != nil { row.add("Аналітика", "так") }

            var uri: String?
            do {
                let r = try await dev.service(ns, "GetStreamUri",
                    "<tr2:GetStreamUri><tr2:Protocol>RTSP</tr2:Protocol>"
                    + "<tr2:ProfileToken>\(xmlEscape(token))</tr2:ProfileToken></tr2:GetStreamUri>")
                uri = r.string("Uri")
                row.add("RTSP URI", uri)
            } catch {
                row.addError(error, title: "RTSP URI")
            }
            do {
                let r = try await dev.service(ns, "GetSnapshotUri",
                    "<tr2:GetSnapshotUri><tr2:ProfileToken>\(xmlEscape(token))</tr2:ProfileToken></tr2:GetSnapshotUri>")
                row.add("Snapshot URI", r.string("Uri"))
            } catch {
                row.addError(error, title: "Snapshot URI")
            }

            node.append(row)
            streams.append(StreamInfo(title: "\(row.title) (Media2)", summary: summary, uri: uri))
        }
        return (node, streams)
    }
}

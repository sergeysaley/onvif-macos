import XCTest
@testable import ONVIFCore

final class ONVIFCoreTests: XCTestCase {
    func testDigestRFC2617Vector() {
        let header = "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", "
            + "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""
        guard let challenge = HTTPAuthChallenge.parse(header) else { return XCTFail("challenge not parsed") }
        XCTAssertEqual(challenge.scheme, .digest)
        let value = challenge.authorization(method: "GET", uri: "/dir/index.html",
                                            credentials: Credentials(username: "Mufasa", password: "Circle Of Life"),
                                            cnonce: "0a4f113b")
        XCTAssertTrue(value.contains("response=\"6629fae49393a05397450978507c4ef1\""), value)
        XCTAssertTrue(value.contains("nc=00000001"), value)
        XCTAssertTrue(value.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""), value)
    }

    func testChallengeWithBasicAfterDigest() {
        let params = HTTPAuthChallenge.parseParams("realm=\"cam\", nonce=\"abc\", qop=auth, Basic realm=\"x\"")
        XCTAssertEqual(params["realm"], "cam")
        XCTAssertEqual(params["nonce"], "abc")
        XCTAssertEqual(params["qop"], "auth")
        XCTAssertNil(params["basic"])
    }

    func testWSSecurityDigest() {
        let nonce = Data((0..<16).map { UInt8($0) })
        let digest = WSSecurity.passwordDigest(nonce: nonce, created: "2024-01-01T00:00:00Z", password: "secret")
        XCTAssertEqual(digest, "vhkNh82r7E2rA9qMKzvKdpwqvjc=")
    }

    func testParseProbeMatch() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
            xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
          <SOAP-ENV:Body>
            <d:ProbeMatches>
              <d:ProbeMatch>
                <wsa:EndpointReference><wsa:Address>urn:uuid:1234</wsa:Address></wsa:EndpointReference>
                <d:Types>dn:NetworkVideoTransmitter</d:Types>
                <d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/Profile/Streaming
                  onvif://www.onvif.org/Profile/T onvif://www.onvif.org/name/Front%20Door
                  onvif://www.onvif.org/hardware/DS-2CD2043</d:Scopes>
                <d:XAddrs>http://10.0.0.5/onvif/device_service http://192.168.1.64/onvif/device_service</d:XAddrs>
                <d:MetadataVersion>1</d:MetadataVersion>
              </d:ProbeMatch>
            </d:ProbeMatches>
          </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """
        let devices = WSDiscovery.parseProbeMatches(Data(xml.utf8), source: "192.168.1.64")
        XCTAssertEqual(devices.count, 1)
        let d = devices[0]
        XCTAssertEqual(d.endpointReference, "urn:uuid:1234")
        XCTAssertEqual(d.name, "Front Door")
        XCTAssertEqual(d.hardware, "DS-2CD2043")
        XCTAssertEqual(d.profiles, ["S", "T"])
        XCTAssertEqual(d.serviceURL?.absoluteString, "http://192.168.1.64/onvif/device_service")
    }

    func testNonONVIFResponderIsFiltered() {
        let pc = DiscoveredDevice(endpointReference: "urn:uuid:d4156b43", types: ["wsdp:Device", "pub:Computer"],
                                  scopes: [], xaddrs: ["http://backup:5357/d4156b43"], metadataVersion: "1",
                                  sourceAddress: "192.168.88.52")
        XCTAssertFalse(pc.isONVIF)
    }

    func testAuthFaultDetection() throws {
        let xml = """
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:ter="http://www.onvif.org/ver10/error">
          <env:Body><env:Fault>
            <env:Code><env:Value>env:Sender</env:Value>
              <env:Subcode><env:Value>ter:NotAuthorized</env:Value></env:Subcode></env:Code>
            <env:Reason><env:Text xml:lang="en">Sender not Authorized</env:Text></env:Reason>
          </env:Fault></env:Body>
        </env:Envelope>
        """
        let root = try XMLTree.parse(Data(xml.utf8))
        guard let fault = root.at("Body", "Fault") else { return XCTFail("no fault") }
        let error = SOAPClient.parseFault(fault)
        XCTAssertTrue(SOAPClient.isAuthFault(error))
        if case .fault(let code, _) = error {
            XCTAssertEqual(code, "Sender / NotAuthorized")
        } else {
            XCTFail("unexpected error")
        }
    }

    func testFormatOffset() {
        XCTAssertEqual(DeviceReporter.formatOffset(-1_030_752), "11 д 22 год 19 хв — годинник пристрою відстає")
        XCTAssertEqual(DeviceReporter.formatOffset(2), "немає (2 с)")
    }

    func testStreamURLWithCredentials() {
        let url = StreamURL.withCredentials("rtsp://192.168.1.10:554/stream1",
                                            Credentials(username: "admin", password: "p@ss"))
        XCTAssertEqual(url?.absoluteString, "rtsp://admin:p%40ss@192.168.1.10:554/stream1")
        let untouched = StreamURL.withCredentials("rtsp://u:p@10.0.0.1/s", Credentials(username: "admin", password: "x"))
        XCTAssertEqual(untouched?.absoluteString, "rtsp://u:p@10.0.0.1/s")
    }

    func testDeviceAddress() {
        XCTAssertEqual(DeviceAddress.url(from: "192.168.1.10")?.absoluteString,
                       "http://192.168.1.10/onvif/device_service")
        XCTAssertEqual(DeviceAddress.url(from: " 10.0.0.2:8080 ")?.absoluteString,
                       "http://10.0.0.2:8080/onvif/device_service")
        XCTAssertTrue(DeviceAddress.sortKey("192.168.1.9") < DeviceAddress.sortKey("192.168.1.10"))
    }

    func testRegisterServiceRewritesHost() {
        let dev = ONVIFDevice(url: URL(string: "http://192.168.1.64/onvif/device_service")!, credentials: nil)
        dev.registerService(ONVIFNamespace.media, xaddr: "http://10.0.0.5/onvif/Media")
        XCTAssertEqual(dev.serviceURLs[ONVIFNamespace.media]?.absoluteString, "http://192.168.1.64/onvif/Media")
    }
}

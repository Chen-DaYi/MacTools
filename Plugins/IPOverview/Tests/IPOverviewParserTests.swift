import XCTest
@testable import IPOverviewPlugin

final class IPOverviewParserTests: XCTestCase {
    func testParsesIPAddressFromJSONPayload() {
        let data = #"{"ip":"203.0.113.8"}"#.data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromJSON(data), "203.0.113.8")
    }

    func testParsesIPAddressFromCloudflareTracePayload() {
        let data = """
        fl=123
        h=4.ipcheck.ing
        ip=2001:db8::1
        ts=1710000000
        """.data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromCloudflareTrace(data), "2001:db8::1")
    }

    func testParsesIPAddressFromBilibiliPayload() {
        let data = """
        {"code":0,"data":{"addr":"203.0.113.8","country":"中国"}}
        """.data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromBilibiliIPService(data), "203.0.113.8")
    }

    func testParsesIPAddressFromCIPText() {
        let data = """
        IP\t: 203.0.113.8
        地址\t: 中国 北京 北京
        """.data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromCIPText(data), "203.0.113.8")
    }

    func testParsesIPAddressFromIPIPText() {
        let data = "当前 IP：203.0.113.8  来自于：中国 北京 北京 电信".data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromIPIPText(data), "203.0.113.8")
    }

    func testParsesIPWhoisGeoPayload() {
        let data = """
        {
          "success": true,
          "country": "United States",
          "region": "California",
          "city": "Los Angeles",
          "connection": {
            "asn": 15169,
            "org": "Google LLC",
            "isp": "Google"
          },
          "timezone": {
            "id": "America/Los_Angeles"
          }
        }
        """.data(using: .utf8)!

        let info = IPOverviewParser.geoInfoFromIPWhois(data, ip: "8.8.8.8")

        XCTAssertEqual(info?.locationText, "United States / California / Los Angeles")
        XCTAssertEqual(info?.asn, "AS15169")
        XCTAssertEqual(info?.organization, "Google LLC")
        XCTAssertEqual(info?.timezone, "America/Los_Angeles")
    }

    func testMapsPreferredLocalizationToGeoLanguageCode() {
        XCTAssertEqual(IPOverviewLocale.geoLanguageCode(preferredLocalization: "zh-Hans"), "zh-CN")
        XCTAssertEqual(IPOverviewLocale.geoLanguageCode(preferredLocalization: "en"), "en")
        XCTAssertNil(IPOverviewLocale.geoLanguageCode(preferredLocalization: "ja"))
    }

    func testIPWhoisGeoURLUsesLanguageCode() {
        let url = IPOverviewGeoSource.ipwhois.url(ip: "8.8.8.8", languageCode: "zh-CN")

        XCTAssertEqual(url.absoluteString, "https://ipwho.is/8.8.8.8?lang=zh-CN")
    }

    func testParsesIPAPIGeoPayload() {
        let data = """
        {
          "country_name": "United States",
          "region": "California",
          "city": "Mountain View",
          "org": "GOOGLE",
          "asn": "AS15169",
          "timezone": "America/Los_Angeles"
        }
        """.data(using: .utf8)!

        let info = IPOverviewParser.geoInfoFromIPAPI(data, ip: "8.8.8.8")

        XCTAssertEqual(info?.locationText, "United States / California / Mountain View")
        XCTAssertEqual(info?.networkText, "AS15169 GOOGLE")
        XCTAssertEqual(info?.source, "ipapi.co")
    }

    func testParsesNetworkQualityPayload() {
        let data = """
        {
          "base_rtt": 42.5,
          "dl_throughput": 125000000,
          "ul_throughput": 32000000,
          "dl_responsiveness": 80,
          "ul_responsiveness": 91.5,
          "dl_phase_duration": 4.2,
          "ul_phase_duration": 3.8,
          "interface_name": "en0",
          "test_endpoint": "example.apple.com",
          "start_date": "2026-06-24 18:02:05.338",
          "end_date": "2026-06-24 18:02:11.095"
        }
        """.data(using: .utf8)!

        let measurement = IPOverviewNetworkQualityParser.measurement(from: data)

        XCTAssertEqual(measurement?.baseRTTMilliseconds, 42.5)
        XCTAssertEqual(measurement?.downloadMbps, 125)
        XCTAssertEqual(measurement?.uploadMbps, 32)
        XCTAssertEqual(measurement?.uploadResponsivenessRPM, 91.5)
        XCTAssertEqual(measurement?.totalPhaseDuration, 8)
        XCTAssertEqual(measurement?.interfaceName, "en0")
        XCTAssertEqual(measurement?.testEndpoint, "example.apple.com")
    }

    func testParsesNetworkQualityVerbosePayload() {
        let data = """
        ==== Verbose Results ====
        Uplink capacity: 29.192 Mbps
        Downlink capacity: 21.801 Mbps
        Idle Latency: 200.707 milliseconds | 298 RPM
        Uplink Responsiveness: Low (304.435 milliseconds | 197 RPM)
        Downlink Responsiveness: Low (356.107 milliseconds | 168 RPM)
        Test Endpoint: example.apple.com
        Interface: en0
        Start: 2026-06-24 19:10:11.260
        End: 2026-06-24 19:10:19.946
        Downlink Phase Length: 3.60s
        Uplink Phase Length: 3.54s
        """.data(using: .utf8)!

        let measurement = IPOverviewNetworkQualityParser.measurement(from: data)

        XCTAssertEqual(measurement?.downloadMbps, 21.801)
        XCTAssertEqual(measurement?.uploadMbps, 29.192)
        XCTAssertEqual(measurement?.baseRTTMilliseconds, 200.707)
        XCTAssertEqual(measurement?.uploadResponsivenessRPM, 197)
        XCTAssertEqual(measurement?.downloadResponsivenessRPM, 168)
        XCTAssertEqual(measurement?.downloadPhaseDuration, 3.60)
        XCTAssertEqual(measurement?.uploadPhaseDuration, 3.54)
        XCTAssertEqual(measurement?.interfaceName, "en0")
        XCTAssertEqual(measurement?.testEndpoint, "example.apple.com")
    }

    func testParsesNetworkQualityProgressEvents() {
        let events = IPOverviewNetworkQualityParser.progressEvents(from: """
        Downlink capacity: 21.801 Mbps
        Uplink capacity: 29.192 Mbps
        Idle Latency: 200.707 milliseconds | 298 RPM
        """)

        XCTAssertTrue(events.contains(.phase(.measuringDownload)))
        XCTAssertTrue(events.contains(.phase(.measuringUpload)))
        XCTAssertTrue(events.contains(.phase(.measuringLatency)))
        XCTAssertTrue(events.contains(.download(21.801)))
        XCTAssertTrue(events.contains(.upload(29.192)))
    }

    func testParsesNetworkQualityTTYProgressEvents() {
        let events = IPOverviewNetworkQualityParser.progressEvents(from: """
        \u{1B}[2K
        Downlink: capacity 26.079 Mbps, responsiveness 147 RPM (17.608 MB, 6 flows) - Uplink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 0 flows)
        """)

        XCTAssertTrue(events.contains(.phase(.measuringDownload)))
        XCTAssertTrue(events.contains(.download(26.079)))
        XCTAssertFalse(events.contains(.phase(.measuringUpload)))
        XCTAssertFalse(events.contains(.upload(0)))
    }

    func testParsesNetworkQualityTTYUploadProgressEvents() {
        let events = IPOverviewNetworkQualityParser.progressEvents(from: """
        \u{1B}[2K
        Downlink: capacity 26.079 Mbps, responsiveness 147 RPM (17.608 MB, 6 flows) - Uplink: capacity 24.039 Mbps, responsiveness 173 RPM (9.562 MB, 5 flows)
        """)

        XCTAssertTrue(events.contains(.phase(.measuringUpload)))
        XCTAssertTrue(events.contains(.upload(24.039)))
        XCTAssertFalse(events.contains(.download(26.079)))
    }

    func testGradesNetworkQualityMeasurement() {
        XCTAssertEqual(
            IPOverviewNetworkQualityGrade.evaluate(
                baseRTTMilliseconds: 45,
                downloadMbps: 150,
                uploadMbps: 50
            ),
            .excellent
        )
        XCTAssertEqual(
            IPOverviewNetworkQualityGrade.evaluate(
                baseRTTMilliseconds: 120,
                downloadMbps: 8,
                uploadMbps: 4
            ),
            .fair
        )
        XCTAssertEqual(
            IPOverviewNetworkQualityGrade.evaluate(
                baseRTTMilliseconds: 240,
                downloadMbps: 2,
                uploadMbps: 0.5
            ),
            .poor
        )
    }

    func testValidatesIPAddressFamily() {
        XCTAssertTrue(IPOverviewService.isValidIPAddress("203.0.113.8", family: .ipv4))
        XCTAssertFalse(IPOverviewService.isValidIPAddress("203.0.113.8", family: .ipv6))
        XCTAssertTrue(IPOverviewService.isValidIPAddress("2001:db8::1", family: .ipv6))
        XCTAssertFalse(IPOverviewService.isValidIPAddress("not-an-ip"))
    }
}

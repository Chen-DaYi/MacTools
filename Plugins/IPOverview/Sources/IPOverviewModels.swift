import Foundation
import MacToolsPluginKit

enum IPOverviewAddressFamily: String, CaseIterable, Codable, Sendable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

enum IPOverviewEgressRoute: String, CaseIterable, Codable, Sendable {
    case domestic
    case international

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .domestic:
            return localization.string("egress.domestic", defaultValue: "国内出口")
        case .international:
            return localization.string("egress.international", defaultValue: "国际出口")
        }
    }
}

struct IPOverviewPublicIPResult: Codable, Equatable, Sendable {
    let family: IPOverviewAddressFamily
    let route: IPOverviewEgressRoute
    let ip: String
    let source: String

    init(
        family: IPOverviewAddressFamily,
        route: IPOverviewEgressRoute = .international,
        ip: String,
        source: String
    ) {
        self.family = family
        self.route = route
        self.ip = ip
        self.source = source
    }
}

struct IPOverviewSourceResult: Identifiable, Codable, Equatable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    let id: String
    let family: IPOverviewAddressFamily
    let route: IPOverviewEgressRoute
    let source: String
    let status: Status

    init(
        id: String,
        family: IPOverviewAddressFamily,
        route: IPOverviewEgressRoute = .international,
        source: String,
        status: Status
    ) {
        self.id = id
        self.family = family
        self.route = route
        self.source = source
        self.status = status
    }
}

struct IPOverviewLocalAddress: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let interfaceName: String
    let address: String
    let family: IPOverviewAddressFamily
}

struct IPOverviewGeoInfo: Codable, Equatable, Sendable {
    let ip: String
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?
    let isp: String?
    let organization: String?
    let asn: String?
    let timezone: String?
    let networkType: IPOverviewNetworkType
    let isProxy: Bool?
    let isHosting: Bool?
    let source: String

    var countryFlag: String? {
        guard let countryCode else {
            return nil
        }

        return IPOverviewFormatter.flagEmoji(countryCode: countryCode)
    }

    var locationText: String? {
        [country, region, city]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " / ")
            .nilIfEmpty
    }

    var countryDisplayText: String? {
        guard let country, !country.isEmpty else {
            return nil
        }

        if let countryFlag {
            return "\(countryFlag) \(country)"
        }

        return country
    }

    var networkText: String? {
        [asn, organization ?? isp]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
            .nilIfEmpty
    }

    var proxyText: String {
        proxyText()
    }

    func proxyText(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch isProxy {
        case true:
            return localization.string("geo.proxy.possible", defaultValue: "可能为代理")
        case false:
            return localization.string("geo.proxy.notDetected", defaultValue: "未识别为代理")
        case nil:
            return localization.string("common.unknown", defaultValue: "未知")
        }
    }
}

enum IPOverviewNetworkType: Codable, Sendable {
    case residential
    case mobile
    case datacenter
    case education
    case business
    case unknown

    var rawValue: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .residential:
            return localization.string("networkType.residential", defaultValue: "住宅/宽带")
        case .mobile:
            return localization.string("networkType.mobile", defaultValue: "移动网络")
        case .datacenter:
            return localization.string("networkType.datacenter", defaultValue: "数据中心")
        case .education:
            return localization.string("networkType.education", defaultValue: "教育网络")
        case .business:
            return localization.string("networkType.business", defaultValue: "企业网络")
        case .unknown:
            return localization.string("common.unknown", defaultValue: "未知")
        }
    }

    static func infer(organization: String?, isp: String?, isHosting: Bool?) -> IPOverviewNetworkType {
        if isHosting == true {
            return .datacenter
        }

        let text = [organization, isp]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard !text.isEmpty else {
            return .unknown
        }

        if text.contains("mobile") || text.contains("wireless") || text.contains("cellular")
            || text.contains("移动") || text.contains("unicom") || text.contains("telecom") {
            return .mobile
        }

        if text.contains("university") || text.contains("education") || text.contains("college") {
            return .education
        }

        if text.contains("cloud") || text.contains("hosting") || text.contains("data")
            || text.contains("amazon") || text.contains("aws") || text.contains("google")
            || text.contains("microsoft") || text.contains("azure") || text.contains("cloudflare")
            || text.contains("digitalocean") || text.contains("hetzner") || text.contains("ovh")
            || text.contains("linode") || text.contains("vultr") {
            return .datacenter
        }

        if text.contains("business") || text.contains("enterprise") || text.contains("corp") {
            return .business
        }

        return .residential
    }
}

struct IPOverviewConnectivityTarget: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var urlString: String
    var isCustom: Bool

    var url: URL? {
        URL(string: urlString)
    }

    static let defaults: [IPOverviewConnectivityTarget] = [
        IPOverviewConnectivityTarget(
            id: "wechat",
            name: "WeChat",
            urlString: "https://res.wx.qq.com/a/wx_fed/assets/res/NTI4MWU5.ico",
            isCustom: false
        ),
        IPOverviewConnectivityTarget(
            id: "google",
            name: "Google",
            urlString: "https://www.google.com/favicon.ico",
            isCustom: false
        ),
        IPOverviewConnectivityTarget(
            id: "cloudflare",
            name: "Cloudflare",
            urlString: "https://www.cloudflare.com/favicon.ico",
            isCustom: false
        ),
        IPOverviewConnectivityTarget(
            id: "youtube",
            name: "YouTube",
            urlString: "https://www.youtube.com/favicon.ico",
            isCustom: false
        ),
        IPOverviewConnectivityTarget(
            id: "github",
            name: "GitHub",
            urlString: "https://github.com/favicon.ico",
            isCustom: false
        ),
        IPOverviewConnectivityTarget(
            id: "chatgpt",
            name: "ChatGPT",
            urlString: "https://chatgpt.com/favicon.ico",
            isCustom: false
        )
    ]
}

struct IPOverviewConnectivityResult: Identifiable, Codable, Equatable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        case waiting
        case checking
        case reachable(milliseconds: Int)
        case unreachable(String)
    }

    let id: String
    let target: IPOverviewConnectivityTarget
    var status: Status

    var latencyMilliseconds: Int? {
        guard case .reachable(let milliseconds) = status else {
            return nil
        }

        return milliseconds
    }
}

enum IPOverviewNetworkQualityRunState: Codable, Equatable, Sendable {
    case waiting
    case running(IPOverviewNetworkQualityProgress)
    case completed(IPOverviewNetworkQualityMeasurement, IPOverviewNetworkQualityProgress)
    case failed(String)

    var measurement: IPOverviewNetworkQualityMeasurement? {
        guard case .completed(let measurement, _) = self else {
            return nil
        }

        return measurement
    }
}

struct IPOverviewNetworkQualityProgress: Codable, Equatable, Sendable {
    var startedAt: Date
    var phase: IPOverviewNetworkQualityPhase
    var downloadSamples: [Double]
    var uploadSamples: [Double]

    static func started(at date: Date = Date()) -> IPOverviewNetworkQualityProgress {
        IPOverviewNetworkQualityProgress(
            startedAt: date,
            phase: .initializing,
            downloadSamples: [],
            uploadSamples: []
        )
    }

    var latestDownloadMbps: Double? {
        downloadSamples.last
    }

    var latestUploadMbps: Double? {
        uploadSamples.last
    }
}

enum IPOverviewNetworkQualityPhase: Codable, Equatable, Sendable {
    case initializing
    case measuringDownload
    case measuringUpload
    case measuringLatency

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .initializing:
            return localization.string("speed.phase.initializing", defaultValue: "准备测速")
        case .measuringDownload:
            return localization.string("speed.phase.download", defaultValue: "测量下载")
        case .measuringUpload:
            return localization.string("speed.phase.upload", defaultValue: "测量上传")
        case .measuringLatency:
            return localization.string("speed.phase.latency", defaultValue: "测量延迟")
        }
    }
}

struct IPOverviewNetworkQualityMeasurement: Codable, Equatable, Sendable {
    let baseRTTMilliseconds: Double?
    let downloadThroughputBitsPerSecond: Double?
    let uploadThroughputBitsPerSecond: Double?
    let downloadResponsivenessRPM: Double?
    let uploadResponsivenessRPM: Double?
    let downloadPhaseDuration: TimeInterval?
    let uploadPhaseDuration: TimeInterval?
    let interfaceName: String?
    let testEndpoint: String?
    let startDate: String?
    let endDate: String?

    var downloadMbps: Double? {
        downloadThroughputBitsPerSecond.map { $0 / 1_000_000 }
    }

    var uploadMbps: Double? {
        uploadThroughputBitsPerSecond.map { $0 / 1_000_000 }
    }

    var totalPhaseDuration: TimeInterval? {
        let durations = [downloadPhaseDuration, uploadPhaseDuration].compactMap(\.self)
        guard !durations.isEmpty else {
            return nil
        }

        return durations.reduce(0, +)
    }

    var quality: IPOverviewNetworkQualityGrade {
        IPOverviewNetworkQualityGrade.evaluate(
            baseRTTMilliseconds: baseRTTMilliseconds,
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps
        )
    }
}

enum IPOverviewNetworkQualityGrade: Sendable {
    case excellent
    case good
    case fair
    case poor
    case unknown

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .excellent:
            return localization.string("speed.grade.excellent", defaultValue: "优秀")
        case .good:
            return localization.string("speed.grade.good", defaultValue: "良好")
        case .fair:
            return localization.string("speed.grade.fair", defaultValue: "一般")
        case .poor:
            return localization.string("speed.grade.poor", defaultValue: "偏慢")
        case .unknown:
            return localization.string("common.unknown", defaultValue: "未知")
        }
    }

    static func evaluate(
        baseRTTMilliseconds: Double?,
        downloadMbps: Double?,
        uploadMbps: Double?
    ) -> IPOverviewNetworkQualityGrade {
        guard baseRTTMilliseconds != nil || downloadMbps != nil || uploadMbps != nil else {
            return .unknown
        }

        let latencyScore: Int
        switch baseRTTMilliseconds {
        case let value? where value <= 50:
            latencyScore = 3
        case let value? where value <= 100:
            latencyScore = 2
        case let value? where value <= 200:
            latencyScore = 1
        case .some:
            latencyScore = 0
        case nil:
            latencyScore = 1
        }

        let downloadScore: Int
        switch downloadMbps {
        case let value? where value >= 100:
            downloadScore = 3
        case let value? where value >= 25:
            downloadScore = 2
        case let value? where value >= 5:
            downloadScore = 1
        case .some:
            downloadScore = 0
        case nil:
            downloadScore = 1
        }

        let uploadScore: Int
        switch uploadMbps {
        case let value? where value >= 40:
            uploadScore = 3
        case let value? where value >= 10:
            uploadScore = 2
        case let value? where value >= 2:
            uploadScore = 1
        case .some:
            uploadScore = 0
        case nil:
            uploadScore = 1
        }

        switch min(latencyScore, downloadScore, uploadScore) {
        case 3:
            return .excellent
        case 2:
            return .good
        case 1:
            return .fair
        default:
            return .poor
        }
    }
}

struct IPOverviewLeakTestResult: Identifiable, Codable, Equatable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        case waiting
        case checking
        case success(IPOverviewLeakEndpoint)
        case failure(String)
    }

    let id: String
    let name: String
    let status: Status

    var endpoint: IPOverviewLeakEndpoint? {
        guard case .success(let endpoint) = status else {
            return nil
        }

        return endpoint
    }

    var isWaiting: Bool {
        guard case .waiting = status else {
            return false
        }

        return true
    }

    var isChecking: Bool {
        guard case .checking = status else {
            return false
        }

        return true
    }

    var isFailure: Bool {
        guard case .failure = status else {
            return false
        }

        return true
    }
}

struct IPOverviewLeakEndpoint: Codable, Equatable, Sendable {
    let ip: String
    let natType: String?
    let country: String?
    let countryCode: String?
    let organization: String?

    var countryDisplayText: String? {
        guard let country, !country.isEmpty else {
            return nil
        }

        if let countryCode, let flag = IPOverviewFormatter.flagEmoji(countryCode: countryCode) {
            return "\(flag) \(country)"
        }

        return country
    }
}

private extension IPOverviewGeoInfo {
    var regionKey: String? {
        IPOverviewRegionKey.countryCodeOrName(countryCode: countryCode, country: country)
    }
}

private extension IPOverviewLeakEndpoint {
    var regionKey: String? {
        IPOverviewRegionKey.countryCodeOrName(countryCode: countryCode, country: country)
    }
}

private enum IPOverviewRegionKey {
    static func countryCodeOrName(countryCode: String?, country: String?) -> String? {
        if let code = countryCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !code.isEmpty {
            return "code:\(code)"
        }

        if let country = country?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !country.isEmpty {
            return "country:\(country)"
        }

        return nil
    }
}

enum IPOverviewLeakAssessmentKind: Equatable, Sendable {
    case webRTC
    case dns
}

enum IPOverviewLeakAssessmentState: Equatable, Sendable {
    case waiting
    case checking
    case clear
    case warning
    case unknown
}

enum IPOverviewLeakAssessmentReason: Equatable, Sendable {
    case waiting
    case checking
    case noPublicIP
    case noDNSEndpoint
    case webRTCMatchesPublicIP
    case webRTCNoVisibleEndpoint
    case webRTCDifferentIP
    case dnsMatchesEgressRegion
    case dnsDifferentEgressRegion
    case dnsObservedWithoutBaselineRegion
}

struct IPOverviewLeakAssessment: Equatable, Sendable {
    let kind: IPOverviewLeakAssessmentKind
    let state: IPOverviewLeakAssessmentState
    let reason: IPOverviewLeakAssessmentReason
    let totalCount: Int
    let observedCount: Int
    let failureCount: Int
    let issueEndpoint: IPOverviewLeakEndpoint?

    static func evaluate(
        kind: IPOverviewLeakAssessmentKind,
        results: [IPOverviewLeakTestResult],
        snapshot: IPOverviewSnapshot,
        isRunning: Bool
    ) -> IPOverviewLeakAssessment {
        let endpoints = results.compactMap(\.endpoint)
        let failureCount = results.filter(\.isFailure).count
        let hasChecking = isRunning || results.contains(where: \.isChecking)
        let isWaitingOnly = !results.isEmpty && results.allSatisfy(\.isWaiting)

        switch kind {
        case .webRTC:
            return evaluateWebRTC(
                results: results,
                endpoints: endpoints,
                snapshot: snapshot,
                isWaitingOnly: isWaitingOnly,
                hasChecking: hasChecking,
                failureCount: failureCount
            )
        case .dns:
            return evaluateDNS(
                results: results,
                endpoints: endpoints,
                snapshot: snapshot,
                isWaitingOnly: isWaitingOnly,
                hasChecking: hasChecking,
                failureCount: failureCount
            )
        }
    }

    private static func evaluateWebRTC(
        results: [IPOverviewLeakTestResult],
        endpoints: [IPOverviewLeakEndpoint],
        snapshot: IPOverviewSnapshot,
        isWaitingOnly: Bool,
        hasChecking: Bool,
        failureCount: Int
    ) -> IPOverviewLeakAssessment {
        let publicIPs = snapshot.publicIPSet

        if !endpoints.isEmpty, !publicIPs.isEmpty,
           let issue = endpoints.first(where: { !publicIPs.contains($0.ip) }) {
            return assessment(
                kind: .webRTC,
                state: .warning,
                reason: .webRTCDifferentIP,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount,
                issueEndpoint: issue
            )
        }

        if hasChecking {
            return assessment(
                kind: .webRTC,
                state: .checking,
                reason: .checking,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        if isWaitingOnly {
            return assessment(
                kind: .webRTC,
                state: .waiting,
                reason: .waiting,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        if endpoints.isEmpty {
            return assessment(
                kind: .webRTC,
                state: .clear,
                reason: .webRTCNoVisibleEndpoint,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        if publicIPs.isEmpty {
            return assessment(
                kind: .webRTC,
                state: .unknown,
                reason: .noPublicIP,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        return assessment(
            kind: .webRTC,
            state: .clear,
            reason: .webRTCMatchesPublicIP,
            results: results,
            observedCount: endpoints.count,
            failureCount: failureCount
        )
    }

    private static func evaluateDNS(
        results: [IPOverviewLeakTestResult],
        endpoints: [IPOverviewLeakEndpoint],
        snapshot: IPOverviewSnapshot,
        isWaitingOnly: Bool,
        hasChecking: Bool,
        failureCount: Int
    ) -> IPOverviewLeakAssessment {
        let baselineRegions = snapshot.publicRegionKeys
        let observedRegions = endpoints.compactMap(\.regionKey)

        if !baselineRegions.isEmpty, !observedRegions.isEmpty,
           let issue = endpoints.first(where: { endpoint in
               guard let regionKey = endpoint.regionKey else {
                   return false
               }
               return !baselineRegions.contains(regionKey)
           }) {
            return assessment(
                kind: .dns,
                state: .warning,
                reason: .dnsDifferentEgressRegion,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount,
                issueEndpoint: issue
            )
        }

        if hasChecking {
            return assessment(
                kind: .dns,
                state: .checking,
                reason: .checking,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        if isWaitingOnly {
            return assessment(
                kind: .dns,
                state: .waiting,
                reason: .waiting,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        if endpoints.isEmpty {
            return assessment(
                kind: .dns,
                state: .unknown,
                reason: .noDNSEndpoint,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        if baselineRegions.isEmpty || observedRegions.isEmpty {
            return assessment(
                kind: .dns,
                state: .unknown,
                reason: .dnsObservedWithoutBaselineRegion,
                results: results,
                observedCount: endpoints.count,
                failureCount: failureCount
            )
        }

        return assessment(
            kind: .dns,
            state: .clear,
            reason: .dnsMatchesEgressRegion,
            results: results,
            observedCount: endpoints.count,
            failureCount: failureCount
        )
    }

    private static func assessment(
        kind: IPOverviewLeakAssessmentKind,
        state: IPOverviewLeakAssessmentState,
        reason: IPOverviewLeakAssessmentReason,
        results: [IPOverviewLeakTestResult],
        observedCount: Int,
        failureCount: Int,
        issueEndpoint: IPOverviewLeakEndpoint? = nil
    ) -> IPOverviewLeakAssessment {
        IPOverviewLeakAssessment(
            kind: kind,
            state: state,
            reason: reason,
            totalCount: results.count,
            observedCount: observedCount,
            failureCount: failureCount,
            issueEndpoint: issueEndpoint
        )
    }
}

struct IPOverviewWebRTCTarget: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: UInt16

    var displayAddress: String {
        "\(host):\(port)"
    }

    static let defaults: [IPOverviewWebRTCTarget] = [
        IPOverviewWebRTCTarget(id: "google", name: "Google", host: "stun.l.google.com", port: 19302),
        IPOverviewWebRTCTarget(id: "blackberry", name: "BlackBerry", host: "stun.voip.blackberry.com", port: 3478),
        IPOverviewWebRTCTarget(id: "twilio", name: "Twilio", host: "global.stun.twilio.com", port: 3478),
        IPOverviewWebRTCTarget(id: "cloudflare", name: "Cloudflare", host: "stun.cloudflare.com", port: 3478)
    ]
}

struct IPOverviewSnapshot: Codable, Equatable, Sendable {
    var domesticIPv4: IPOverviewPublicIPResult?
    var domesticIPv6: IPOverviewPublicIPResult?
    var internationalIPv4: IPOverviewPublicIPResult?
    var internationalIPv6: IPOverviewPublicIPResult?
    var localAddresses: [IPOverviewLocalAddress]
    var geoInfoByIP: [String: IPOverviewGeoInfo]
    var sourceResults: [IPOverviewSourceResult]
    var lastUpdated: Date?
    var errorMessage: String?
    var isRefreshing: Bool

    static let empty = IPOverviewSnapshot(
        domesticIPv4: nil,
        domesticIPv6: nil,
        internationalIPv4: nil,
        internationalIPv6: nil,
        localAddresses: [],
        geoInfoByIP: [:],
        sourceResults: [],
        lastUpdated: nil,
        errorMessage: nil,
        isRefreshing: false
    )

    init(
        domesticIPv4: IPOverviewPublicIPResult? = nil,
        domesticIPv6: IPOverviewPublicIPResult? = nil,
        internationalIPv4: IPOverviewPublicIPResult? = nil,
        internationalIPv6: IPOverviewPublicIPResult? = nil,
        localAddresses: [IPOverviewLocalAddress],
        geoInfoByIP: [String: IPOverviewGeoInfo],
        sourceResults: [IPOverviewSourceResult],
        lastUpdated: Date?,
        errorMessage: String?,
        isRefreshing: Bool
    ) {
        self.domesticIPv4 = domesticIPv4
        self.domesticIPv6 = domesticIPv6
        self.internationalIPv4 = internationalIPv4
        self.internationalIPv6 = internationalIPv6
        self.localAddresses = localAddresses
        self.geoInfoByIP = geoInfoByIP
        self.sourceResults = sourceResults
        self.lastUpdated = lastUpdated
        self.errorMessage = errorMessage
        self.isRefreshing = isRefreshing
    }

    init(
        publicIPv4: IPOverviewPublicIPResult?,
        publicIPv6: IPOverviewPublicIPResult?,
        localAddresses: [IPOverviewLocalAddress],
        geoInfoByIP: [String: IPOverviewGeoInfo],
        sourceResults: [IPOverviewSourceResult],
        lastUpdated: Date?,
        errorMessage: String?,
        isRefreshing: Bool
    ) {
        self.init(
            internationalIPv4: publicIPv4,
            internationalIPv6: publicIPv6,
            localAddresses: localAddresses,
            geoInfoByIP: geoInfoByIP,
            sourceResults: sourceResults,
            lastUpdated: lastUpdated,
            errorMessage: errorMessage,
            isRefreshing: isRefreshing
        )
    }

    var publicIPv4: IPOverviewPublicIPResult? {
        internationalIPv4
    }

    var publicIPv6: IPOverviewPublicIPResult? {
        internationalIPv6
    }

    var preferredPublicIP: IPOverviewPublicIPResult? {
        internationalIPv4 ?? internationalIPv6 ?? domesticIPv4 ?? domesticIPv6
    }

    var preferredGeoInfo: IPOverviewGeoInfo? {
        guard let ip = preferredPublicIP?.ip else {
            return nil
        }

        return geoInfoByIP[ip]
    }

    var publicIPSet: Set<String> {
        Set([internationalIPv4?.ip, internationalIPv6?.ip].compactMap { $0 })
    }

    var publicRegionKeys: Set<String> {
        Set(publicIPSet.compactMap { geoInfoByIP[$0]?.regionKey })
    }

    var reportText: String {
        reportText()
    }

    func reportText(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        var lines: [String] = []
        lines.append(localization.string("report.title", defaultValue: "IP 检测结果"))
        if let lastUpdated {
            lines.append(localization.format(
                "report.updatedAt",
                defaultValue: "更新时间：%@",
                IPOverviewFormatter.dateTime(lastUpdated)
            ))
        }
        let notDetected = localization.string("common.notDetected", defaultValue: "未检测到")
        lines.append(localization.format("report.domesticIPv4", defaultValue: "国内出口 IPv4：%@", domesticIPv4?.ip ?? notDetected))
        lines.append(localization.format("report.domesticIPv6", defaultValue: "国内出口 IPv6：%@", domesticIPv6?.ip ?? notDetected))
        lines.append(localization.format("report.publicIPv4", defaultValue: "国际出口 IPv4：%@", internationalIPv4?.ip ?? notDetected))
        lines.append(localization.format("report.publicIPv6", defaultValue: "国际出口 IPv6：%@", internationalIPv6?.ip ?? notDetected))

        if !localAddresses.isEmpty {
            lines.append("")
            lines.append(localization.string("report.localAddresses", defaultValue: "本地地址："))
            for address in localAddresses {
                lines.append(localization.format(
                    "report.localAddress",
                    defaultValue: "- %@ %@：%@",
                    address.interfaceName,
                    address.family.rawValue,
                    address.address
                ))
            }
        }

        if !geoInfoByIP.isEmpty {
            lines.append("")
            lines.append(localization.string("report.geo", defaultValue: "归属地："))
            for info in geoInfoByIP.values.sorted(by: { $0.ip < $1.ip }) {
                lines.append("- \(info.ip)")
                if let country = info.countryDisplayText {
                    lines.append(localization.format("report.region", defaultValue: "  地区：%@", country))
                }
                if let region = info.region, !region.isEmpty {
                    lines.append(localization.format("report.province", defaultValue: "  省份：%@", region))
                }
                if let city = info.city, !city.isEmpty {
                    lines.append(localization.format("report.city", defaultValue: "  城市：%@", city))
                }
                if let network = info.networkText {
                    lines.append(localization.format("report.network", defaultValue: "  网络：%@", network))
                }
                if let timezone = info.timezone, !timezone.isEmpty {
                    lines.append(localization.format("report.timezone", defaultValue: "  时区：%@", timezone))
                }
                lines.append(localization.format("report.source", defaultValue: "  来源：%@", info.source))
            }
        }

        if !sourceResults.isEmpty {
            lines.append("")
            lines.append(localization.string("report.sources", defaultValue: "检测源："))
            for result in sourceResults {
                switch result.status {
                case .success(let ip):
                    lines.append(localization.format(
                        "report.source.success",
                        defaultValue: "- %@ %@：%@",
                        result.route.title(localization: localization),
                        result.source,
                        ip
                    ))
                case .failure(let message):
                    lines.append(localization.format(
                        "report.source.failure",
                        defaultValue: "- %@ %@：失败（%@）",
                        result.route.title(localization: localization),
                        result.source,
                        message
                    ))
                }
            }
        }

        if let errorMessage, !errorMessage.isEmpty {
            lines.append("")
            lines.append(localization.format("report.error", defaultValue: "错误：%@", errorMessage))
        }

        return lines.joined(separator: "\n")
    }
}

enum IPOverviewFormatter {
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func flagEmoji(countryCode: String) -> String? {
        let code = countryCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard code.count == 2 else {
            return nil
        }

        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard let regionalIndicator = UnicodeScalar(127397 + scalar.value) else {
                return nil
            }
            scalars.append(regionalIndicator)
        }

        return String(scalars)
    }
}

enum IPOverviewSensitiveValueMask {
    static func maskedIP(_ value: String) -> String {
        if value.contains(":") {
            return maskedIPv6(value)
        }

        return maskedIPv4(value)
    }

    private static func maskedIPv4(_ value: String) -> String {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return "••••"
        }

        return "\(parts[0]).\(parts[1]).•••.•••"
    }

    private static func maskedIPv6(_ value: String) -> String {
        let visibleParts = value
            .split(separator: ":", omittingEmptySubsequences: true)
            .prefix(2)
        guard !visibleParts.isEmpty else {
            return "••••:••••"
        }

        return "\(visibleParts.joined(separator: ":")):••••:••••"
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

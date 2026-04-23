import Foundation
import CoreLocation
import WebKit
import Contacts

/// Bridges browser `navigator.geolocation` calls from widget JS to CoreLocation.
///
/// Widgets send `{type: "registerCallback"|"removeCallback", callbackId}` messages
/// via the `geolocation` WKScriptMessage channel. We invoke
/// `__UBCallbacks__.call(id, payload)` in the page when we have a fix.
///
/// Replaces `UBLocation.m`. Two material upgrades over the old code:
///   • JSON is produced by `JSONEncoder`, not `stringWithFormat:` — no more
///     quote-injection risk via the reverse-geocoded address strings.
///   • Reverse geocoding uses `CNPostalAddress` (the `addressDictionary`
///     property was deprecated in macOS 10.13).
@objc(UBLocation)
@MainActor
public final class Geolocation: NSObject, WKScriptMessageHandler {

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var waiting: [String: WKScriptMessage] = [:]
    private var currentPayload: String?
    private var serviceStarted = false

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    // MARK: - WKScriptMessageHandler

    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKScriptMessageHandler is documented to deliver on the main thread;
        // hop explicitly to keep Swift's actor checker happy under strict
        // concurrency.
        MainActor.assumeIsolated {
            handle(message)
        }
    }

    private func handle(_ message: WKScriptMessage) {
        guard
            let body = message.body as? [String: Any],
            let type = body["type"] as? String,
            let callbackId = body["callbackId"] as? String
        else { return }

        switch type {
        case "registerCallback":
            if !serviceStarted { startService() }
            waiting[callbackId] = message
            if let payload = currentPayload {
                respond(to: message, payload: payload)
            }
        case "removeCallback":
            waiting.removeValue(forKey: callbackId)
            if waiting.isEmpty { stopService() }
        default:
            break
        }
    }

    // MARK: - Service lifecycle

    private func startService() {
        guard !serviceStarted else { return }
        locationManager.startUpdatingLocation()
        serviceStarted = true
    }

    private func stopService() {
        guard serviceStarted else { return }
        locationManager.stopUpdatingLocation()
        currentPayload = nil
        serviceStarted = false
    }

    // MARK: - Response

    private func respond(to message: WKScriptMessage, payload: String) {
        guard let webView = message.webView else { return }
        let body = body(forCallbackId: message.body as? [String: Any], payload: payload)
        webView.evaluateJavaScript(body, completionHandler: nil)
    }

    private func body(forCallbackId bodyDict: [String: Any]?, payload: String) -> String {
        let callbackId = (bodyDict?["callbackId"] as? String) ?? ""
        // The page has `__UBCallbacks__.call` already installed via the
        // `geolocation.js` user script. We interpolate the id + JSON payload.
        return "__UBCallbacks__.call(\(callbackId.jsQuoted), \(payload))"
    }

    // MARK: - Geocoding + payload

    private func broadcast(payload: String) {
        currentPayload = payload
        for (_, message) in waiting {
            respond(to: message, payload: payload)
        }
    }

    fileprivate func handleLocationUpdate(_ location: CLLocation) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            let payload = Self.makePayload(location: location, placemark: placemarks?.first)
            Task { @MainActor [weak self] in
                self?.broadcast(payload: payload)
            }
        }
    }

    nonisolated static func makePayload(location: CLLocation, placemark: CLPlacemark?) -> String {
        let payload = GeolocationPayload(
            position: .init(
                timestamp: location.timestamp.timeIntervalSince1970 * 1000,
                coords: .init(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.altitude,
                    accuracy: location.horizontalAccuracy,
                    altitudeAccuracy: location.verticalAccuracy,
                    heading: location.course,
                    speed: location.speed
                )
            ),
            address: .init(
                street: placemark?.postalAddress?.street ?? placemark?.thoroughfare ?? "",
                city: placemark?.postalAddress?.city ?? placemark?.locality ?? "",
                zip: placemark?.postalAddress?.postalCode ?? placemark?.postalCode ?? "",
                country: placemark?.postalAddress?.country ?? placemark?.country ?? "",
                state: placemark?.postalAddress?.state ?? placemark?.administrativeArea ?? "",
                CountryCode: placemark?.postalAddress?.isoCountryCode ?? placemark?.isoCountryCode ?? ""
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(payload),
            let s = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return s
    }
}

// MARK: - CLLocationManagerDelegate

extension Geolocation: CLLocationManagerDelegate {
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.handleLocationUpdate(location)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        // Match the old behavior: swallow the error. The widget gets no
        // callback fire; next successful update broadcasts.
    }
}

// MARK: - Payload types

struct GeolocationPayload: Encodable {
    let position: Position
    let address: Address

    struct Position: Encodable {
        let timestamp: Double
        let coords: Coords
    }

    struct Coords: Encodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let accuracy: Double
        let altitudeAccuracy: Double
        let heading: Double
        let speed: Double
    }

    struct Address: Encodable {
        let street: String
        let city: String
        let zip: String
        let country: String
        let state: String
        // Preserve the exact key casing the old JS-facing format used.
        let CountryCode: String
    }
}

// MARK: - Helpers

private extension String {
    /// Serializes this string as a JSON string literal, escaped so it can be
    /// interpolated into a JavaScript callback invocation safely.
    var jsQuoted: String {
        guard
            let data = try? JSONEncoder().encode(self),
            let s = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return s
    }
}

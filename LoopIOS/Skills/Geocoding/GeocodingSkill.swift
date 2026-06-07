//
//  GeocodingSkill.swift
//  Loop
//

import Foundation
import CoreLocation

/// Lets Loop turn a street address (or place name) into latitude/longitude
/// coordinates via CoreLocation's CLGeocoder. This is the inverse of the
/// reverse-geocode that LocationSkill does on the device's own position:
/// here the model supplies an address string and gets back coordinates plus a
/// normalized, geocoder-canonicalized address.
///
/// Unlike LocationSkill, this needs no location permission — geocoding an
/// arbitrary address is a network lookup, not a read of the device's position.
///
/// Tools the model sees:
/// - geocode_address: address string -> { latitude, longitude, formatted_address, ... }
struct GeocodingSkill {
    static let shared = GeocodingSkill()

    static let systemPromptFragment: String = """
You can convert an address or place name into map coordinates with this tool:
- geocode_address: takes an `address` string and returns its latitude/longitude plus a normalized address and (when available) locality, region, and country.

When to call:
- The user gives an address and you need coordinates ("where is 1 Infinite Loop, Cupertino?", "pin this address on a map").
- You need lat/lon to feed another tool that expects coordinates (e.g. a map embed or a nearby search) and only have a textual address.

Notes:
- This does NOT use the device's location and needs no permission — it geocodes whatever address you pass.
- For the user's *own* current position, use get_current_location instead.
- An ambiguous or unknown address returns an error string; relay it and ask the user to clarify (add city/state/country).
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "geocode_address",
                "description": "Convert a street address or place name into latitude/longitude coordinates. Returns the coordinates and a normalized address. Does not require location permission.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "address": [
                            "type": "string",
                            "description": "The address or place name to geocode, e.g. \"1600 Amphitheatre Parkway, Mountain View, CA\". Include city/state/country when possible to disambiguate."
                        ]
                    ],
                    "required": ["address"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "geocode_address"
    ]

    func handles(functionName: String) -> Bool {
        return GeocodingSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "geocode_address":
            if let address = call.arguments["address"] as? String, !address.isEmpty {
                return "geocoding \(address.prefix(40))"
            }
            return "geocoding address"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "geocode_address":
            let address = (functionCall.arguments["address"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            geocode(address: address, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Geocoding tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    private func geocode(address: String,
                         completion: @escaping (MessageStruct) -> Void) {
        guard !address.isEmpty else {
            completion(Self.result("Provide a non-empty `address` to geocode."))
            return
        }

        // CLGeocoder is single-shot and retains itself for the duration of the
        // request, but we hold a local reference until the callback fires so
        // ARC doesn't release it mid-flight.
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address) { placemarks, error in
            if let error = error {
                // CLError.geocodeFoundNoResult reads better as "not found".
                let detail: String
                if (error as? CLError)?.code == .geocodeFoundNoResult {
                    detail = "no matching location found"
                } else {
                    detail = error.localizedDescription
                }
                completion(Self.result("Could not geocode \"\(address)\": \(detail). Try adding a city, state, or country to disambiguate."))
                return
            }
            guard let placemark = placemarks?.first,
                  let location = placemark.location else {
                completion(Self.result("No coordinates found for \"\(address)\". Try adding a city, state, or country to disambiguate."))
                return
            }

            var payload: [String: Any] = [
                "status": "ok",
                "query": address,
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "formatted_address": Self.formatAddress(placemark)
            ]
            if let locality = placemark.locality { payload["locality"] = locality }
            if let region = placemark.administrativeArea { payload["region"] = region }
            if let postal = placemark.postalCode { payload["postal_code"] = postal }
            if let country = placemark.country { payload["country"] = country }
            if let isoCountry = placemark.isoCountryCode { payload["country_code"] = isoCountry }

            let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            completion(Self.result(json))
        }
    }

    // MARK: - Helpers

    private static func result(_ body: String) -> MessageStruct {
        return MessageStruct(role: "function", content: body, name: "geocode_address")
    }

    /// Builds a single normalized address line from a placemark's components,
    /// skipping nils and the redundant `name`-equals-thoroughfare case.
    private static func formatAddress(_ placemark: CLPlacemark) -> String {
        var parts: [String] = []
        if let name = placemark.name, name != placemark.thoroughfare {
            parts.append(name)
        } else if let thoroughfare = placemark.thoroughfare {
            if let sub = placemark.subThoroughfare {
                parts.append("\(sub) \(thoroughfare)")
            } else {
                parts.append(thoroughfare)
            }
        }
        if let locality = placemark.locality { parts.append(locality) }
        if let admin = placemark.administrativeArea { parts.append(admin) }
        if let postal = placemark.postalCode { parts.append(postal) }
        if let country = placemark.country { parts.append(country) }

        // De-dup consecutive repeats (e.g. name already contains the city).
        var unique: [String] = []
        for part in parts where unique.last != part {
            unique.append(part)
        }
        return unique.joined(separator: ", ")
    }
}

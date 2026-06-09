//
//  GoogleCalendarSkill.swift
//  Loop
//
//  Google Calendar integration via the Calendar v3 REST API. Reads the
//  user's access token from KeyStore (Settings → Keys → Google Workspace
//  Access Token). Mirrors SlackSkill/NotionSkill's shape: static tool
//  schemas, a dispatch method, and structured JSON responses.
//
//  Note: This is separate from the existing CalendarSkill which uses
//  Apple's EventKit. This skill talks directly to Google Calendar's REST
//  API for users who want deeper Google Calendar access.
//

import Foundation

struct GoogleCalendarSkill {
    static let shared = GoogleCalendarSkill()

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can access the user's Google Calendar through these tools:
- google_calendar (action: "list_events"): list calendar events. Optional params: calendarId (default "primary"), timeMin (RFC3339), timeMax (RFC3339), maxResults (default 10, max 50).
- google_calendar (action: "create_event"): create a new event. Params: summary (required), start (required, RFC3339 datetime or date), end (required, RFC3339 datetime or date), description (optional), attendees (optional array of email strings), calendarId (optional, default "primary").

Workflow tips:
- Use RFC3339 timestamps like "2024-03-15T09:00:00-07:00" or date-only "2024-03-15" for all-day events.
- If a tool returns {"error":"google_not_connected"}, tell the user to paste their Google access token in Settings → Keys → Google Workspace Access Token.
- If a tool returns {"error":"token_expired"}, tell the user their Google token has expired and they need to refresh it.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "google_calendar",
                "description": "Interact with Google Calendar. Specify an action and its parameters.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list_events", "create_event"],
                            "description": "The Calendar action to perform."
                        ],
                        "calendarId": [
                            "type": "string",
                            "description": "Calendar id. Defaults to 'primary'."
                        ],
                        "timeMin": [
                            "type": "string",
                            "description": "Lower bound for event start time (RFC3339, for list_events). E.g. '2024-03-15T00:00:00Z'."
                        ],
                        "timeMax": [
                            "type": "string",
                            "description": "Upper bound for event start time (RFC3339, for list_events)."
                        ],
                        "maxResults": [
                            "type": "integer",
                            "description": "Max events to return for list_events. Default 10, max 50."
                        ],
                        "summary": [
                            "type": "string",
                            "description": "Event title (for create_event)."
                        ],
                        "start": [
                            "type": "string",
                            "description": "Event start time as RFC3339 datetime or date string (for create_event)."
                        ],
                        "end": [
                            "type": "string",
                            "description": "Event end time as RFC3339 datetime or date string (for create_event)."
                        ],
                        "description": [
                            "type": "string",
                            "description": "Event description (optional, for create_event)."
                        ],
                        "attendees": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional array of attendee email addresses (for create_event)."
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["google_calendar"]

    func handles(functionName: String) -> Bool {
        return GoogleCalendarSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "google_calendar" else { return nil }
        let action = call.arguments["action"] as? String ?? ""
        switch action {
        case "list_events":  return "listing Google Calendar events"
        case "create_event":
            if let summary = call.arguments["summary"] as? String, !summary.isEmpty {
                return "creating event: \(summary)"
            }
            return "creating a calendar event"
        default:             return "accessing Google Calendar"
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        guard let action = args["action"] as? String, !action.isEmpty else {
            completion(missingArgs(expected: "action")); return
        }
        switch action {
        case "list_events":
            listEvents(calendarId: args["calendarId"] as? String,
                       timeMin: args["timeMin"] as? String,
                       timeMax: args["timeMax"] as? String,
                       maxResults: intArg(args["maxResults"]),
                       completion: completion)
        case "create_event":
            guard let summary = args["summary"] as? String, !summary.isEmpty,
                  let start = args["start"] as? String, !start.isEmpty,
                  let end = args["end"] as? String, !end.isEmpty else {
                completion(missingArgs(expected: "summary, start, end")); return
            }
            createEvent(calendarId: args["calendarId"] as? String,
                        summary: summary,
                        start: start,
                        end: end,
                        description: args["description"] as? String,
                        attendees: args["attendees"] as? [String],
                        completion: completion)
        default:
            completion(functionMessage(payload: [
                "error": "unknown_action",
                "hint": "Valid actions: list_events, create_event"
            ]))
        }
    }

    // MARK: - Actions

    private func listEvents(calendarId: String?,
                            timeMin: String?,
                            timeMax: String?,
                            maxResults: Int?,
                            completion: @escaping (MessageStruct) -> Void) {
        let calendar = calendarId ?? "primary"
        let count = min(max(maxResults ?? 10, 1), 50)
        var queryItems = [
            URLQueryItem(name: "maxResults", value: "\(count)"),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime")
        ]
        if let timeMin, !timeMin.isEmpty {
            queryItems.append(URLQueryItem(name: "timeMin", value: timeMin))
        }
        if let timeMax, !timeMax.isEmpty {
            queryItems.append(URLQueryItem(name: "timeMax", value: timeMax))
        }

        let encodedCalendar = calendar.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendar)/events",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                let items = (dict["items"] as? [[String: Any]] ?? []).map(trimEvent)
                completion(functionMessage(payload: ["events": items]))
            }
        }
    }

    private func createEvent(calendarId: String?,
                             summary: String,
                             start: String,
                             end: String,
                             description: String?,
                             attendees: [String]?,
                             completion: @escaping (MessageStruct) -> Void) {
        let calendar = calendarId ?? "primary"

        var body: [String: Any] = ["summary": summary]

        // Determine if datetime or date based on whether value contains "T"
        if start.contains("T") {
            body["start"] = ["dateTime": start]
            body["end"] = ["dateTime": end]
        } else {
            body["start"] = ["date": start]
            body["end"] = ["date": end]
        }

        if let description, !description.isEmpty {
            body["description"] = description
        }
        if let attendees, !attendees.isEmpty {
            body["attendees"] = attendees.map { ["email": $0] }
        }

        let encodedCalendar = calendar.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar
        GoogleWorkspaceClient.shared.post(
            url: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendar)/events",
            body: body
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                completion(functionMessage(payload: [
                    "status": "created",
                    "id": dict["id"] as? String ?? "",
                    "htmlLink": dict["htmlLink"] as? String ?? "",
                    "summary": dict["summary"] as? String ?? summary
                ]))
            }
        }
    }

    // MARK: - Helpers

    private func trimEvent(_ event: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [
            "id": event["id"] as? String ?? "",
            "summary": event["summary"] as? String ?? "(no title)"
        ]
        if let start = event["start"] as? [String: Any] {
            out["start"] = start["dateTime"] as? String ?? start["date"] as? String ?? ""
        }
        if let end = event["end"] as? [String: Any] {
            out["end"] = end["dateTime"] as? String ?? end["date"] as? String ?? ""
        }
        if let htmlLink = event["htmlLink"] as? String {
            out["htmlLink"] = htmlLink
        }
        if let description = event["description"] as? String, !description.isEmpty {
            out["description"] = description
        }
        if let attendees = event["attendees"] as? [[String: Any]] {
            out["attendees"] = attendees.map { a in
                [
                    "email": a["email"] as? String ?? "",
                    "responseStatus": a["responseStatus"] as? String ?? ""
                ]
            }
        }
        if let status = event["status"] as? String {
            out["status"] = status
        }
        return out
    }

    private func errorMessage(error: GoogleWorkspaceClient.GoogleError) -> MessageStruct {
        let payload: [String: Any] = [
            "error": error.code,
            "hint": error.hint
        ]
        return functionMessage(payload: payload)
    }

    private func functionMessage(payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: "google_calendar")
    }

    private func missingArgs(expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call google_calendar. Please provide them."
        )
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}

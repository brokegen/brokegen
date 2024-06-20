import Foundation
import SwiftyJSON

fileprivate let microsecondDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"

    return formatter
}()

fileprivate func microsecondDate(from dateString0: String) throws -> Date {
    var dateString = dateString0

    // TODO: Need to check timezones on these strings, maybe
    if dateString.last == "Z" {
        dateString = String(dateString.dropLast(1))
    }
    if let fractionStart = dateString.range(of: ".", options: .backwards) {
        // Or, sometimes, Ollama will return fewer digits, apparently because the last few are zero.
        let digitsExtant = dateString.suffix(from: fractionStart.upperBound).count
        if digitsExtant >= 0 && digitsExtant < 6 {
            dateString += String(repeating: "0", count: 6 - digitsExtant)
        }
    }
    dateString += "Z"

    /// from https://stackoverflow.com/questions/28016578/
    guard var date = microsecondDateFormatter.date(from: dateString) else { throw ChatMessageError.failedDateDecoding }
    date = Date(
        timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate)
    )

    if let fractionStart = dateString.range(of: "."),
       let fractionEnd = dateString.index(fractionStart.lowerBound, offsetBy: 7, limitedBy: dateString.endIndex)
    {
        // fractionString should a string containing six decimal digits.
        let fractionString = dateString[fractionStart.lowerBound..<fractionEnd].trimmingPrefix(".")

        // Directly converting with `Double` introduces rounding errors; `.065005` becomes `.065004`.
        if let fraction = Int(fractionString) {
            date.addTimeInterval(Double(fraction) / pow(10, Double(fractionString.count)))
        }
    }

    return date
}

fileprivate func microsecondDateString(from date0: Date) -> String {
    // Directly converting with `super` introduces errors; `.999500` adds a second.
    var dateString = microsecondDateFormatter.string(
        from: Date(timeIntervalSince1970: floor(date0.timeIntervalSince1970))
    )

    if let fractionStart = dateString.range(of: "."),
       let fractionEnd = dateString.index(fractionStart.lowerBound, offsetBy: 7, limitedBy: dateString.endIndex)
    {
        // Replace the decimal range with the six digit fraction
        let microseconds = date0.timeIntervalSince1970 - floor(date0.timeIntervalSince1970)
        var microsecondsString = String(format: "%.06f", microseconds)
        microsecondsString.remove(at: microsecondsString.startIndex)

        let fractionRange = fractionStart.lowerBound..<fractionEnd
        dateString.replaceSubrange(fractionRange, with: microsecondsString)
    }

    return dateString
}

let jsonDecoder: JSONDecoder = { preserveMicroseconds in
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    if preserveMicroseconds {
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            var dateString = try container.decode(String.self)

            return try microsecondDate(from: dateString)
        }
    }
    else {
        decoder.dateDecodingStrategy = .custom { decoder in
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let container = try decoder.singleValueContainer()
            if let maybeDate: Date = try dateFormatter.date(from: container.decode(String.self) + "Z") {
                return maybeDate
            } else {
                throw ChatMessageError.failedDateDecoding
            }
        }
    }

    return decoder
}(true)


let jsonEncoder: JSONEncoder = { preserveMicroseconds in
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase

    if preserveMicroseconds {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(microsecondDateString(from: date))
        }
    }
    else {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
    }

    return encoder
}(true)

public enum JSONObject: Codable {
    case string(String)
    case number(Float)
    case object([String:JSONObject])
    case array([JSONObject])
    case bool(Bool)
    case null
}

/// TODO: Replace use of Codable with SwiftyJSON
/// This makes more sense for very-variable JSON blobs, particularly those that don't have explicit typing
/// (i.e. those not under our control, like whatever fields come down for provider/modelIdentifiers).
extension JSON {
    public var isoDate: Date? {
        get {
            if let objectString = self.string {
                return try? microsecondDate(from: objectString)
            }
            else {
                return nil
            }
        }
    }

    public var isoDateValue: Date {
        get {
            return self.isoDate ?? Date.distantPast
        }
        set {
            self.stringValue = microsecondDateString(from: newValue)
        }
    }
}

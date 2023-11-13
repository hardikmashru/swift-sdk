//
//  File.swift
//  
//
//  Created by HARDIK MASHRU on 13/11/23.
//

import Foundation

// Convert commerce items to dictionaries
func convertCommerceItemsToDictionary(_ items: [CommerceItem]) -> [[AnyHashable:Any]] {
    let dictionaries = items.map { item in
        return item.toDictionary()
    }
    return dictionaries
}

// Convert to commerce items from dictionaries
func convertCommerceItems(from dictionaries: [[AnyHashable: Any]]) -> [CommerceItem] {
    return dictionaries.compactMap { dictionary in
        let item = CommerceItem(id: dictionary[JsonKey.CommerceItem.id] as? String ?? "", name: dictionary[JsonKey.CommerceItem.name] as? String ?? "", price: dictionary[JsonKey.CommerceItem.price] as? NSNumber ?? 0, quantity: dictionary[JsonKey.CommerceItem.quantity] as? UInt ?? 0)
        item.sku = dictionary[JsonKey.CommerceItem.sku] as? String
        item.itemDescription = dictionary[JsonKey.CommerceItem.description] as? String
        item.url = dictionary[JsonKey.CommerceItem.url] as? String
        item.imageUrl = dictionary[JsonKey.CommerceItem.imageUrl] as? String
        item.categories = dictionary[JsonKey.CommerceItem.categories] as? [String]
        item.dataFields = dictionary[JsonKey.CommerceItem.dataFields] as? [AnyHashable: Any]

        return item
    }
}

func convertToDictionary(data: Codable) -> [AnyHashable: Any] {
    do {
        let encoder = JSONEncoder()
        let data = try encoder.encode(data)
        if let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [AnyHashable: Any] {
            return dictionary
        }
    } catch {
        print("Error converting to dictionary: \(error)")
    }
    return [:]
}

// Converts UTC Datetime from current time
func getUTCDateTime() -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    dateFormatter.timeZone = TimeZone(identifier: "UTC")
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    
    let utcDate = Date()
    return dateFormatter.string(from: utcDate)
}

struct CriteriaCompletionChecker {
    init(anonymousCriteria: Data, anonymousEvents: [[AnyHashable: Any]]) {
        self.anonymousEvents = anonymousEvents
        self.anonymousCriteria = anonymousCriteria
    }
    
    func getMatchedCriteria() -> Int? {
        var criteriaId: Int? = nil
        if let json = try? JSONSerialization.jsonObject(with: anonymousCriteria, options: []) as? [String: Any] {
            // Access the criteriaList
            if let criteriaList = json["criteriaList"] as? [[String: Any]] {
                // Iterate over the criteria
                for criteria in criteriaList {
                    // Perform operations on each criteria
                    if let searchQuery = criteria["searchQuery"] as? [String: Any], let currentCriteriaId = criteria["criteriaId"] as? Int {
                        var eventsToProcess = getPurchaseEventsToProcess()
                        eventsToProcess.append(contentsOf: getNonPurchaseEvents())
                        let result = evaluateTree(node: searchQuery, localEventData: eventsToProcess)
                        if (result) {
                            criteriaId = currentCriteriaId
                            break
                        }
                    }
                }
            }
        }
        return criteriaId
    }
    
    func getMappedKeys(event: [AnyHashable: Any]) -> [String] {
        var itemKeys: [String] = []
        for (_ , value) in event {
            if let arrayValue = value as? [[AnyHashable: Any]], arrayValue.count > 0 { // this is a special case of items array in purchase event
                // If the value is an array, handle it
                itemKeys.append(contentsOf: extractKeys(dict: arrayValue[0]))
            } else {
                itemKeys.append(contentsOf: extractKeys(dict: event))
            }
        }
        return itemKeys
    }
    
    func getNonPurchaseEvents() -> [[AnyHashable: Any]] {
        let nonPurchaseEvents = anonymousEvents.filter { dictionary in
            if let dataType = dictionary[JsonKey.eventType] as? String {
                return dataType != EventType.purchase
            }
            return false
        }
        return nonPurchaseEvents
    }
    
    func getPurchaseEventsToProcess() -> [[AnyHashable: Any]] {
        let purchaseEvents = anonymousEvents.filter { dictionary in
            if let dataType = dictionary[JsonKey.eventType] as? String {
                return dataType == EventType.purchase
            }
            return false
        }
        
        var processedEvents: [[AnyHashable: Any]] = [[:]]
        for item in purchaseEvents {
            if let items = item["items"] as? [[AnyHashable: Any]] {
                let itemsWithTotal = items.map { item -> [AnyHashable: Any] in
                    var itemWithTotal = item
                    let total = item["total"] as? String
                    itemWithTotal["total"] = total
                    return itemWithTotal
                }
                processedEvents.append(contentsOf: itemsWithTotal)
            }
        }
        return processedEvents
    }
    
    func extractKeys(jsonObject: [String: Any]) -> [String] {
        return Array(jsonObject.keys)
    }
    
    func extractKeys(dict: [AnyHashable: Any]) -> [String] {
        var keys: [String] = []
        for key in dict.keys {
            if let stringKey = key as? String {
                // If needed, use stringKey which is now guaranteed to be a String
                keys.append(stringKey)
            }
        }
        return keys
    }

    func evaluateTree(node: [String: Any], localEventData: [[AnyHashable: Any]]) -> Bool {
        if let searchQueries = node["searchQueries"] as? [[String: Any]], let combinator = node["combinator"] as? String {
            if combinator == "And" {
                for query in searchQueries {
                    if !evaluateTree(node: query, localEventData: localEventData) {
                        return false  // If any subquery fails, return false
                    }
                }
                return true  // If all subqueries pass, return true
            } else if combinator == "Or" {
                for query in searchQueries {
                    if evaluateTree(node: query, localEventData: localEventData) {
                        return true  // If any subquery passes, return true
                    }
                }
                return false  // If all subqueries fail, return false
            }
        } else if let searchCombo = node["searchCombo"] as? [String: Any] {
            return evaluateTree(node: searchCombo, localEventData: localEventData)
        } else if node["field"] != nil {
            return evaluateField(node: node, localEventData: localEventData)
        }
        
        return false
    }

    func evaluateField(node: [String: Any], localEventData: [[AnyHashable: Any]]) -> Bool {
        do {
            return try evaluateFieldLogic(node: node, localEventData: localEventData)
        } catch {
            print("evaluateField JSON ERROR: \(error)")
        }
        return false
    }

    func evaluateFieldLogic(node: [String: Any], localEventData: [[AnyHashable: Any]]) throws -> Bool {
        var isEvaluateSuccess = false
        for eventData in localEventData {
            let localDataKeys = eventData.keys
            if let field = node["field"] as? String,
               let comparatorType = node["comparatorType"] as? String,
               let fieldType = node["fieldType"] as? String {
                for key in localDataKeys {
                    if field.hasSuffix(key as! String), let matchObj = eventData[key] {
                        if evaluateComparison(comparatorType: comparatorType, fieldType: fieldType, matchObj: matchObj, node: node) {
                            isEvaluateSuccess = true
                            break
                        }
                    }
                }
            }
        }
        return isEvaluateSuccess
    }

    func evaluateComparison(comparatorType: String, fieldType: String, matchObj: Any, node: [String: Any]) -> Bool {
        
        if let valueAsString = node["value"] as? String {
            switch comparatorType {
                case "Equals":
                    return compareEqual(matchObj, stringValue: valueAsString)
                case "DoesNotEquals":
                    return compareNotEqual(matchObj, stringValue: valueAsString)
                case "GreaterThan":
                    return compareGreaterThan(matchObj, stringValue: valueAsString)
                case "LessThan":
                    return compareLessThan(matchObj, stringValue: valueAsString)
                case "GreaterThanOrEqualTo":
                    return compareGreaterThanEqualTo(matchObj, stringValue: valueAsString)
                case "LessThanOrEqualTo":
                    return compareLessThanEqualTo(matchObj, stringValue: valueAsString)
                case "Contains":
                    return contains(matchObj, stringValue: valueAsString)
                case "StartsWith":
                    return startsWith(matchObj, stringValue: valueAsString)
                case "MatchesRegex":
                    return compareWithRegex(matchObj as? String ?? "", pattern: valueAsString)
                default:
                    return false
            }
        }
        return false
    }
    
    func compareWithRegex(_ sourceTo: String, pattern: String) -> Bool {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(sourceTo.startIndex..<sourceTo.endIndex, in: sourceTo)
            return regex.firstMatch(in: sourceTo, options: [], range: range) != nil
        } catch {
            print("Error creating regex: \(error)")
            return false
        }
    }
    
    func startsWith(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let stringTypeValue as String:
                return stringTypeValue.starts(with:stringValue)
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func contains(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let stringTypeValue as String:
                return stringTypeValue.contains(stringValue)
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func compareEqual(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let doubleNumber as Double:
                return doubleNumber == Double(stringValue)
            case let intNumber as Int:
                return intNumber == Int(stringValue)
            case let longNumber as Int64:
                return longNumber == Int64(stringValue)
            case let booleanValue as Bool:
                return booleanValue == Bool(stringValue)
            case let stringTypeValue as String:
                return stringTypeValue == stringValue
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func compareNotEqual(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let doubleNumber as Double:
                return doubleNumber != Double(stringValue)
            case let intNumber as Int:
                return intNumber != Int(stringValue)
            case let longNumber as Int64:
                return longNumber != Int64(stringValue)
            case let booleanValue as Bool:
                return booleanValue != Bool(stringValue)
            case let stringTypeValue as String:
                return stringTypeValue != stringValue
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func compareGreaterThan(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let doubleNumber as Double:
                return doubleNumber > Double(stringValue) ?? 0.0
            case let intNumber as Int:
            return intNumber > Int(stringValue) ?? 0
            case let longNumber as Int64:
                return longNumber > Int64(stringValue) ?? 0
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func compareLessThan(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let doubleNumber as Double:
                return doubleNumber < Double(stringValue) ?? 0.0
            case let intNumber as Int:
            return intNumber < Int(stringValue) ?? 0
            case let longNumber as Int64:
                return longNumber < Int64(stringValue) ?? 0
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func compareGreaterThanEqualTo(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let doubleNumber as Double:
                return doubleNumber >= Double(stringValue) ?? 0.0
            case let intNumber as Int:
            return intNumber >= Int(stringValue) ?? 0
            case let longNumber as Int64:
                return longNumber >= Int64(stringValue) ?? 0
            default:
                return false // Or handle other types accordingly
        }
    }
    
    func compareLessThanEqualTo(_ sourceTo: Any, stringValue: String) -> Bool {
        switch sourceTo {
            case let doubleNumber as Double:
                return doubleNumber <= Double(stringValue) ?? 0.0
            case let intNumber as Int:
            return intNumber <= Int(stringValue) ?? 0
            case let longNumber as Int64:
                return longNumber <= Int64(stringValue) ?? 0
            default:
                return false // Or handle other types accordingly
        }
    }
    
    private let anonymousCriteria: Data
    private let anonymousEvents: [[AnyHashable: Any]]
}

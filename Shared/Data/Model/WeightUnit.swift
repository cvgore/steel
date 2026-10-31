//
//  WeightUnit.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 16.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

enum WeightUnit: String, CaseIterable, Hashable {
    case metric
    case imperial
    
    var title: String {
        switch self {
        case .metric:
            return L10n.string("Metric (kg)")
        case .imperial:
            return L10n.string("Imperial (lb)")
        }
    }
    
    var unit: UnitMass {
        switch self {
        case .metric:
            return .kilograms
        case .imperial:
            return .pounds
        }
    }
}

extension WeightUnit {
    var minimumFractionDigits: Int { 0 }
    var maximumFractionDigits: Int { 3 }
    var defaultFractionDigits: Int {
        switch self {
        case .metric:
            return 1
        case .imperial:
            return 0
        }
    }
    
    var numberFormatter: NumberFormatter {
        let numberFormatter = NumberFormatter()
        numberFormatter.locale = L10n.locale
        numberFormatter.allowsFloats = true
        numberFormatter.minimumFractionDigits = minimumFractionDigits
        numberFormatter.maximumFractionDigits = maximumFractionDigits
        return numberFormatter
    }
    
    var formatter: MeasurementFormatter {
        let formatter = MeasurementFormatter()
        formatter.locale = L10n.locale
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter = numberFormatter
        return formatter
    }
}

extension WeightUnit {
    static func convert(weight: Double, from: WeightUnit, to: WeightUnit) -> Double {
        Measurement(value: weight, unit: from.unit).converted(to: to.unit).value
    }
    
    static func format(weight: Double, from: WeightUnit, to: WeightUnit) -> String {
        to.formatter.string(from: Measurement(value: weight, unit: from.unit).converted(to: to.unit))
    }
}

extension WeightUnit {
    var barbellIncrement: Double {
        switch self {
        case .metric:
            return 2.5 // 2x 1.25 kg
        case .imperial:
            return 5 // 2x 2.5 lb
        }
    }
    
    var barbellWeight: Double {
        switch self {
        case .metric:
            return 20
        case .imperial:
            return 45
        }
    }
}
